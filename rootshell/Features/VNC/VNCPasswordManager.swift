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
/// Device passwords are keyed by `RemoteScreenPasswordIdentity.passwordKey`
/// ("user@host:port via route"), stored synchronizable (iCloud Keychain) in the shared access group, with
/// after-first-unlock accessibility unless the instance asks for stricter.
/// No biometric gating: access control flags can't sync.
/// Passwords never appear in profile JSON, CKRecords, or window state; this
/// manager is the only place they live.
@MainActor
@Observable
class VNCPasswordManager {
    nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VNCPasswordManager")

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

    /// Typed passwords on their way from the connect form to the attempt it
    /// starts, never persisted. MainView claims one for that attempt in the
    /// same call, and the form drops any left over, so no other pane takes it.
    private var ephemeralPasswords: [String: String] = [:]

    func stashEphemeralPassword(_ password: String, for key: String) {
        ephemeralPasswords[key] = password
    }

    func hasEphemeralPassword(for key: String) -> Bool {
        ephemeralPasswords[key] != nil
    }

    /// Takes (and removes) a stashed password as a handoff for one attempt.
    func takeEphemeralPassword(for key: String) -> RemoteScreenPasswordHandoff? {
        ephemeralPasswords.removeValue(forKey: key)
            .map { RemoteScreenPasswordHandoff(password: $0, passwordKey: key) }
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

    // MARK: - Error Types

    enum PasswordError: LocalizedError {
        case notFound
        case dataConversionFailed
        case unexpectedStatus(OSStatus)
        /// The route's jump profile isn't on this device, so no password belongs to it.
        case jumpProfileMissing

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Password not found."
            case .jumpProfileMissing:
                return VNCLaunchError.jumpProfileNotFound.localizedDescription
            case .dataConversionFailed:
                return "Password data could not be converted."
            case .unexpectedStatus(let status):
                return "Keychain error (status \(status))."
            }
        }
    }
}
