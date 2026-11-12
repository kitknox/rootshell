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
/// stored synchronizable (iCloud Keychain) in the shared access group, with
/// after-first-unlock accessibility unless the instance asks for stricter.
/// No biometric gating: access control flags can't sync.
/// Passwords never appear in profile JSON, CKRecords, or window state; this
/// manager is the only place they live.
@MainActor
@Observable
class VNCPasswordManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VNCPasswordManager")

    static let shared = VNCPasswordManager(service: "com.ghostty.vnc.password")
    /// KVM over IP device passwords, keyed by `KVMConnectionConfig.passwordKey`.
    static let kvm = VNCPasswordManager(service: "com.rootshell.kvm.password")
    /// Passwords typed into the computer behind a KVM, keyed by
    /// `KVMConnectionConfig.hostPasswordKey(profileID:)`. Only typed on a
    /// user's confirmation, so readable only while the device is unlocked.
    static let kvmHost = VNCPasswordManager(
        service: "com.rootshell.kvm.host-password",
        accessibility: kSecAttrAccessibleWhenUnlocked)

    private nonisolated let service: String
    private let accessibility: CFString
    private nonisolated static let accessGroup = AppIdentifiers.keychainAccessGroup

    /// Bumped on every save or delete so views re-check `hasPassword`.
    private(set) var revision = 0

    private init(service: String, accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock) {
        self.service = service
        self.accessibility = accessibility
    }

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
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            revision &+= 1
            return
        }
        guard updateStatus == errSecItemNotFound else {
            Self.logger.error("Failed to update VNC password - Status: \(updateStatus)")
            throw PasswordError.unexpectedStatus(updateStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrAccessible as String: accessibility,
            kSecAttrSynchronizable as String: true,
            kSecValueData as String: passwordData
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.logger.error("Failed to save VNC password - Status: \(addStatus)")
            throw PasswordError.unexpectedStatus(addStatus)
        }
        revision &+= 1
    }

    /// Loads the VNC password for a connection key.
    func loadPassword(for key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
            kSecAttrService as String: service,
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
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordError.unexpectedStatus(status)
        }
        if status == errSecSuccess { revision &+= 1 }
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
