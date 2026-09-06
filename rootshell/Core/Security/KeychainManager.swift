import Foundation
import LocalAuthentication
import os.log
import Security

@MainActor
class KeychainManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KeychainManager")

    nonisolated static let shared = KeychainManager()

    // Keychain access group shared between iOS and Mac Catalyst
    // Uses Team ID prefix to ensure consistent access across platforms
    // Must match the keychain-access-groups in entitlements: $(AppIdentifierPrefix)$(ROOTSHELL_KEYCHAIN_GROUP_SUFFIX)
    nonisolated private let accessGroup = AppIdentifiers.keychainAccessGroup

    nonisolated private init() {
        Self.logger.info("KeychainManager initialized")
        Self.logger.info("Access Group: \(self.accessGroup)")
        Self.logger.info("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        #if targetEnvironment(macCatalyst)
        Self.logger.info("Platform: Mac Catalyst")
        #else
        Self.logger.info("Platform: iOS")
        #endif
    }

    enum KeychainError: LocalizedError {
        case itemNotFound
        case duplicateItem
        case unexpectedStatus(OSStatus)
        case dataConversionFailed
        case authenticationCancelled
        case authenticationFailed
        case accessControlCreationFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Item not found in keychain"
            case .duplicateItem:
                return "Item already exists in keychain"
            case .unexpectedStatus(let status):
                return "Keychain error: \(status)"
            case .dataConversionFailed:
                return "Failed to convert keychain data"
            case .authenticationCancelled:
                return "Authentication was cancelled"
            case .authenticationFailed:
                return "Authentication failed"
            case .accessControlCreationFailed(let error):
                return "Failed to create access control: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    // MARK: - Private Key Storage

    /// Saves an SSH private key to the Keychain
    /// - Parameters:
    ///   - keyData: The private key data (PEM or OpenSSH format)
    ///   - identifier: Unique identifier for the key (typically UUID)
    /// - Throws: KeychainError if save fails
    func savePrivateKey(_ keyData: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: identifier,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false, // Keep keys local only
            kSecAttrAccessGroup as String: accessGroup
        ]

        Self.logger.debug("savePrivateKey - Account: \(identifier), Data size: \(keyData.count) bytes")

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            Self.logger.error("savePrivateKey failed - Status: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Saves an SSH private key with security configuration
    /// - Parameters:
    ///   - keyData: The private key data (PEM or OpenSSH format)
    ///   - identifier: Unique identifier for the key (typically UUID)
    ///   - storageLevel: Controls where/how the key is stored
    ///   - authRequirement: Controls when authentication is required
    /// - Throws: KeychainError if save fails
    func savePrivateKey(
        _ keyData: Data,
        identifier: String,
        storageLevel: KeyStorageLevel,
        authRequirement: KeyAuthRequirement
    ) throws {
        // iCloud sync is incompatible with SecAccessControl (biometric/passcode flags).
        // Apple rejects the combination with errSecParam (-50).
        let effectiveAuth = (storageLevel == .iCloudSync) ? KeyAuthRequirement.none : authRequirement

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: identifier,
            kSecValueData as String: keyData,
            kSecAttrAccessGroup as String: accessGroup
        ]

        // Configure storage level (accessibility and sync)
        switch storageLevel {
        case .deviceOnly:
            // Most secure: not synced, not backed up
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            // Moderate: backed up but not synced
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            // Least restrictive: synced via iCloud Keychain
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }

        // Add access control for biometric/passcode authentication if required
        if effectiveAuth != .none {
            if let accessControl = try createAccessControl(
                for: storageLevel,
                authRequirement: effectiveAuth
            ) {
                // When using access control, remove the accessibility attribute
                // as it's already specified in the access control
                query.removeValue(forKey: kSecAttrAccessible as String)
                query[kSecAttrAccessControl as String] = accessControl
                Self.logger.debug("savePrivateKey - Access control created and added to query")
            } else {
                Self.logger.warning("savePrivateKey - Access control creation returned nil")
            }
        }

        Self.logger.debug("savePrivateKey (secure) - Account: \(identifier), StorageLevel: \(storageLevel.rawValue), AuthRequirement: \(effectiveAuth.rawValue), HasAccessControl: \(query[kSecAttrAccessControl as String] != nil), Data size: \(keyData.count) bytes")

        let status = SecItemAdd(query as CFDictionary, nil)

        Self.logger.debug("savePrivateKey (secure) - Status: \(status)")
        if status != errSecSuccess {
            Self.logger.error("savePrivateKey (secure) - Error: \(status) (\(Self.keychainErrorString(status)))")
            if status == errSecParam && storageLevel == .iCloudSync {
                Self.logger.error("savePrivateKey - iCloud sync with SecAccessControl is unsupported. Ensure iCloud Keychain is enabled and no biometric flags are set.")
            }
        }

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Creates a SecAccessControl object for biometric/passcode authentication
    private func createAccessControl(
        for storageLevel: KeyStorageLevel,
        authRequirement: KeyAuthRequirement
    ) throws -> SecAccessControl? {
        guard authRequirement != .none else { return nil }

        // Determine accessibility based on storage level
        let accessibility: CFString
        switch storageLevel {
        case .deviceOnly:
            accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .backupOnly, .iCloudSync:
            accessibility = kSecAttrAccessibleWhenUnlocked
        }

        // Check if biometrics are available
        let context = LAContext()
        let biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        // Configure access control flags
        // - biometryCurrentSet: Requires Face ID/Touch ID with current enrollment
        // - devicePasscode: Allows passcode as fallback if biometry fails or is unavailable
        // Using both allows Face ID first, with passcode fallback
        let flags: SecAccessControlCreateFlags
        if biometricsAvailable {
            // Prefer biometrics but allow passcode fallback
            flags = [.biometryCurrentSet, .or, .devicePasscode]
            Self.logger.debug("createAccessControl - Using biometryCurrentSet OR devicePasscode (biometrics available: \(String(describing: context.biometryType)))")
        } else {
            // No biometrics, just use passcode
            flags = [.devicePasscode]
            Self.logger.debug("createAccessControl - Using devicePasscode only (no biometrics available)")
        }

        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            accessibility,
            flags,
            &error
        ) else {
            throw KeychainError.accessControlCreationFailed(error?.takeRetainedValue())
        }

        Self.logger.debug("createAccessControl - Successfully created access control")
        return accessControl
    }

    // Helper to get human-readable error strings
    private static func keychainErrorString(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess: return "Success"
        case errSecItemNotFound: return "Item not found"
        case errSecDuplicateItem: return "Duplicate item"
        case errSecAuthFailed: return "Authentication failed"
        case -34018: return "Missing entitlement or access denied"
        case errSecMissingEntitlement: return "Missing entitlement"
        default: return "Unknown error"
        }
    }

    /// Loads an SSH private key from the Keychain
    /// - Parameter identifier: Unique identifier for the key
    /// - Returns: The private key data
    /// - Throws: KeychainError if load fails
    nonisolated func loadPrivateKey(identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    /// Checks for a private-key item without requesting its secret data.
    /// Used by sync discovery so authentication-gated key material is never
    /// needlessly copied into app memory merely to prove that an item exists.
    nonisolated func sshPrivateKeyExists(
        identifier: String,
        synchronizable: Bool? = nil
    ) throws -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: identifier,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable
        } else {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads an SSH private key with optional authentication
    /// - Parameters:
    ///   - identifier: Unique identifier for the key
    ///   - authRequirement: The authentication requirement for this key
    ///   - context: Optional LAContext for authentication (reused for perSession)
    /// - Returns: The private key data
    /// - Throws: KeychainError if load fails or authentication is cancelled/failed
    func loadPrivateKey(
        identifier: String,
        authRequirement: KeyAuthRequirement,
        context: LAContext?
    ) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        // Add authentication context if provided
        // The LAContext's interactionNotAllowed property (default: false) controls
        // whether authentication UI is shown. No need for deprecated kSecUseAuthenticationUI.
        if authRequirement != .none, let laContext = context {
            query[kSecUseAuthenticationContext as String] = laContext
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.dataConversionFailed
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled:
            throw KeychainError.authenticationCancelled
        case errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes an SSH private key from the Keychain
    /// - Parameter identifier: Unique identifier for the key
    /// - Throws: KeychainError if deletion fails
    func deletePrivateKey(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Updates an existing private key in the Keychain
    /// - Parameters:
    ///   - keyData: The new private key data
    ///   - identifier: Unique identifier for the key
    /// - Throws: KeychainError if update fails
    /// Updates only `kSecValueData`, preserving accessibility, sync class,
    /// and access control. Pass an authenticated `context` to update an
    /// ACL-protected item without a second biometric prompt.
    nonisolated func updatePrivateKey(_ keyData: Data, identifier: String, context: LAContext? = nil) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

        let attributes: [String: Any] = [
            kSecValueData as String: keyData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Passphrase Storage

    /// Saves a passphrase for an encrypted SSH key
    /// - Parameters:
    ///   - passphrase: The passphrase string
    ///   - identifier: Unique identifier for the key (should match the key identifier)
    /// - Throws: KeychainError if save fails
    func savePassphrase(_ passphrase: String, forKey identifier: String) throws {
        guard let passphraseData = passphrase.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.passphrase",
            kSecAttrAccount as String: identifier,
            kSecValueData as String: passphraseData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads a passphrase for an encrypted SSH key
    /// - Parameter identifier: Unique identifier for the key
    /// - Returns: The passphrase string, or nil if not found
    nonisolated func loadPassphrase(forKey identifier: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.passphrase",
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let passphrase = String(data: data, encoding: .utf8) else {
            return nil
        }

        return passphrase
    }

    /// Deletes a passphrase for an encrypted SSH key
    /// - Parameter identifier: Unique identifier for the key
    func deletePassphrase(forKey identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.passphrase",
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup
        ]

        SecItemDelete(query as CFDictionary)
        // Ignore errors - passphrase may not exist
    }

    // MARK: - OpenPubkey Secrets Storage

    /// Saves the OpenPubkey secrets blob (refresh token + compact PK token)
    /// for an opkssh identity key. Overwrites any existing blob, since
    /// renewals rewrite it. Storage placement mirrors the owning key's
    /// storage level (same mapping as `savePrivateKey(_:identifier:storageLevel:authRequirement:)`)
    /// so a synced key carries its refresh token along and a device-only
    /// key's tokens stay out of backups. No access control: renewal must
    /// run silently at connection time.
    /// - Parameters:
    ///   - data: JSON-encoded OpenPubkeySecrets
    ///   - identifier: The owning SSHKey's UUID string
    ///   - storageLevel: The owning key's storage level
    func saveOpenPubkeySecrets(_ data: Data, forKey identifier: String, storageLevel: KeyStorageLevel) throws {
        deleteOpenPubkeySecrets(forKey: identifier)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.openpubkey",
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: accessGroup
        ]

        switch storageLevel {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads the OpenPubkey secrets blob for an opkssh identity key.
    nonisolated func loadOpenPubkeySecrets(forKey identifier: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.openpubkey",
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    /// Deletes the OpenPubkey secrets blob for an opkssh identity key.
    func deleteOpenPubkeySecrets(forKey identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.openpubkey",
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        SecItemDelete(query as CFDictionary)
        // Ignore errors - secrets may not exist
    }

    // MARK: - List Keys

    /// Lists all SSH private key identifiers stored in the Keychain
    /// - Returns: Array of key identifiers
    func listPrivateKeyIdentifiers() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            item[kSecAttrAccount as String] as? String
        }
    }

    // MARK: - Kubeconfig Storage

    /// Saves a kubeconfig to the Keychain
    /// - Parameters:
    ///   - kubeconfigData: The kubeconfig YAML data
    ///   - identifier: Unique identifier for the cluster (typically UUID)
    /// - Throws: KeychainError if save fails
    func saveKubeconfig(_ kubeconfigData: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.kubernetes.kubeconfig",
            kSecAttrAccount as String: identifier,
            kSecValueData as String: kubeconfigData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        Self.logger.debug("saveKubeconfig - Saving kubeconfig for cluster: \(identifier), Data size: \(kubeconfigData.count) bytes")

        var status = SecItemAdd(query as CFDictionary, nil)

        // If item already exists, update it instead
        if status == errSecDuplicateItem {
            Self.logger.debug("saveKubeconfig - Item exists, updating instead")
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.ghostty.kubernetes.kubeconfig",
                kSecAttrAccount as String: identifier,
                kSecAttrAccessGroup as String: accessGroup
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: kubeconfigData
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        Self.logger.debug("saveKubeconfig - Status: \(status)")
        if status != errSecSuccess {
            Self.logger.error("saveKubeconfig - Error: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads a kubeconfig from the Keychain
    /// - Parameter identifier: Unique identifier for the cluster
    /// - Returns: The kubeconfig YAML data
    /// - Throws: KeychainError if load fails
    func loadKubeconfig(identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.kubernetes.kubeconfig",
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    /// Deletes a kubeconfig from the Keychain
    /// - Parameter identifier: Unique identifier for the cluster
    /// - Throws: KeychainError if deletion fails
    func deleteKubeconfig(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.kubernetes.kubeconfig",
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Updates an existing kubeconfig in the Keychain
    /// - Parameters:
    ///   - kubeconfigData: The new kubeconfig YAML data
    ///   - identifier: Unique identifier for the cluster
    /// - Throws: KeychainError if update fails
    func updateKubeconfig(_ kubeconfigData: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.kubernetes.kubeconfig",
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: kubeconfigData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Lists all kubeconfig identifiers stored in the Keychain
    /// - Returns: Array of cluster identifiers
    func listKubeconfigIdentifiers() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.kubernetes.kubeconfig",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            item[kSecAttrAccount as String] as? String
        }
    }

    // MARK: - Cloud Credentials Storage

    private let cloudCredentialsService = "com.ghostty.cloud.credentials"

    /// Saves cloud provider credentials to the Keychain
    /// - Parameters:
    ///   - credentialsData: The credentials encoded as JSON Data
    ///   - identifier: Unique identifier for the account (typically UUID)
    /// - Throws: KeychainError if save fails
    func saveCloudCredentials(_ credentialsData: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: credentialsData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        Self.logger.debug("saveCloudCredentials - Account: \(identifier), Data size: \(credentialsData.count) bytes")

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            Self.logger.error("saveCloudCredentials failed - Status: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads cloud provider credentials from the Keychain
    /// - Parameter identifier: Unique identifier for the account
    /// - Returns: The credentials as JSON Data
    /// - Throws: KeychainError if load fails
    func loadCloudCredentials(identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    /// Updates existing cloud credentials in the Keychain
    /// - Parameters:
    ///   - credentialsData: The new credentials encoded as JSON Data
    ///   - identifier: Unique identifier for the account
    /// - Throws: KeychainError if update fails
    func updateCloudCredentials(_ credentialsData: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: credentialsData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes cloud credentials from the Keychain
    /// - Parameter identifier: Unique identifier for the account
    /// - Throws: KeychainError if deletion fails
    func deleteCloudCredentials(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Lists all cloud credential identifiers stored in the Keychain
    /// - Returns: Array of account identifiers
    func listCloudCredentialIdentifiers() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialsService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            item[kSecAttrAccount as String] as? String
        }
    }

    // MARK: - WiFi AP Credentials Storage

    private let wifiAPCredentialsService = "com.ghostty.wifiap.credentials"

    func saveWiFiAPCredentials(_ credentialsData: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: wifiAPCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: credentialsData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            Self.logger.error("saveWiFiAPCredentials failed - Status: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func loadWiFiAPCredentials(identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: wifiAPCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    func updateWiFiAPCredentials(_ credentialsData: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: wifiAPCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: credentialsData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteWiFiAPCredentials(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: wifiAPCredentialsService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Scrollback Encryption Key Storage

    private let scrollbackEncryptionService = "com.ghostty.scrollback.encryptionkey"

    func saveScrollbackEncryptionKey(_ keyData: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scrollbackEncryptionService,
            kSecAttrAccount as String: "default",
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let dataSize = keyData.count
        Self.logger.debug("saveScrollbackEncryptionKey - Data size: \(dataSize) bytes")

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Upsert: update existing key
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: scrollbackEncryptionService,
                kSecAttrAccount as String: "default",
                kSecAttrAccessGroup as String: accessGroup
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: keyData
            ]
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                Self.logger.error("saveScrollbackEncryptionKey update failed - Status: \(updateStatus)")
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            Self.logger.error("saveScrollbackEncryptionKey failed - Status: \(status) (\(Self.keychainErrorString(status)))")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func loadScrollbackEncryptionKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scrollbackEncryptionService,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    // MARK: - Clipboard History Encryption Key Storage

    private let clipboardEncryptionService = "com.ghostty.clipboard.encryptionkey"

    func saveClipboardEncryptionKey(_ keyData: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: clipboardEncryptionService,
            kSecAttrAccount as String: "default",
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Upsert: update existing key
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: clipboardEncryptionService,
                kSecAttrAccount as String: "default",
                kSecAttrAccessGroup as String: accessGroup
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: keyData
            ]
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                Self.logger.error("saveClipboardEncryptionKey update failed - Status: \(updateStatus)")
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            Self.logger.error("saveClipboardEncryptionKey failed - Status: \(status) (\(Self.keychainErrorString(status)))")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func loadClipboardEncryptionKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: clipboardEncryptionService,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    func deleteClipboardEncryptionKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: clipboardEncryptionService,
            kSecAttrAccount as String: "default",
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Auto-Redact List Storage

    // The auto-redact strings are PII by definition, so the whole encoded
    // list lives in the Keychain rather than UserDefaults. The item is
    // synchronizable: iCloud Keychain carries it end-to-end encrypted so
    // the list follows the user's devices. Early builds stored it as a
    // this-device-only item; reads fall back to that copy and migrate it.

    private let redactionListService = "com.ghostty.redaction.items"

    private func redactionBaseQuery(synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: redactionListService,
            kSecAttrAccount as String: "default",
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }

    func saveRedactionItems(_ data: Data) throws {
        var query = redactionBaseQuery(synchronizable: true)
        query[kSecValueData as String] = data
        // ThisDeviceOnly accessibility classes cannot be synchronizable.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(
                redactionBaseQuery(synchronizable: true) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                Self.logger.error("saveRedactionItems update failed - Status: \(updateStatus)")
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else {
            guard status == errSecSuccess else {
                Self.logger.error("saveRedactionItems failed - Status: \(status) (\(Self.keychainErrorString(status)))")
                throw KeychainError.unexpectedStatus(status)
            }
        }

        // Remove any legacy device-only copy so stale data can't shadow
        // the synced item on this device.
        _ = SecItemDelete(redactionBaseQuery(synchronizable: false) as CFDictionary)
    }

    func loadRedactionItems() throws -> Data {
        do {
            return try copyRedactionItems(synchronizable: true)
        } catch KeychainError.itemNotFound {
            // Fall through to the legacy device-only item.
        }

        let legacy = try copyRedactionItems(synchronizable: false)
        do {
            // Migrate so other devices can pick the list up.
            try saveRedactionItems(legacy)
        } catch {
            Self.logger.error("Failed to migrate redaction items to synced storage: \(error.localizedDescription)")
        }
        return legacy
    }

    private func copyRedactionItems(synchronizable: Bool) throws -> Data {
        var query = redactionBaseQuery(synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    func deleteRedactionItems() throws {
        for synchronizable in [true, false] {
            let status = SecItemDelete(redactionBaseQuery(synchronizable: synchronizable) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }

    // MARK: - SSH Key Metadata Storage

    nonisolated private let sshKeyMetadataService = "com.ghostty.ssh.keymetadata"

    /// Saves SSH key metadata to the Keychain
    /// - Parameters:
    ///   - metadata: The SSHKey metadata encoded as JSON Data
    ///   - identifier: The key's UUID string
    ///   - storageLevel: Controls sync behavior (matches the private key's setting)
    /// - Throws: KeychainError if save fails
    func saveSSHKeyMetadata(
        _ metadata: Data,
        identifier: String,
        storageLevel: KeyStorageLevel
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: metadata,
            kSecAttrAccessGroup as String: accessGroup
        ]

        // Match sync behavior to storageLevel (same as private key)
        switch storageLevel {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }

        // NO access control - metadata doesn't need biometric auth

        Self.logger.debug("saveSSHKeyMetadata - Account: \(identifier), StorageLevel: \(storageLevel.rawValue), Data size: \(metadata.count) bytes")

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            Self.logger.error("saveSSHKeyMetadata failed - Status: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads SSH key metadata from the Keychain
    /// - Parameter identifier: The key's UUID string
    /// - Returns: The metadata as JSON Data
    /// - Throws: KeychainError if load fails
    nonisolated func loadSSHKeyMetadata(identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Include both synced and non-synced
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    /// Updates existing SSH key metadata in the Keychain
    /// - Parameters:
    ///   - metadata: The new metadata encoded as JSON Data
    ///   - identifier: The key's UUID string
    /// - Throws: KeychainError if update fails
    func updateSSHKeyMetadata(_ metadata: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Include both synced and non-synced
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: metadata
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes SSH key metadata from the Keychain
    /// - Parameter identifier: The key's UUID string
    /// - Throws: KeychainError if deletion fails
    func deleteSSHKeyMetadata(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Include both synced and non-synced
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Lists all SSH key metadata identifiers stored in the Keychain
    /// - Returns: Array of key UUID strings
    nonisolated func listSSHKeyMetadataIdentifiers() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyMetadataService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Include both synced and non-synced
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            item[kSecAttrAccount as String] as? String
        }
    }

    /// Discovers all SSH key metadata items for sync detection
    /// - Returns: Array of tuples containing (identifier, metadata Data, isSynced flag)
    nonisolated func discoverAllSSHKeyMetadata() -> [(identifier: String, data: Data, isSynced: Bool)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyMetadataService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Include both synced and non-synced
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                return nil
            }
            let isSynced = (item[kSecAttrSynchronizable as String] as? Bool) ?? false
            return (account, data, isSynced)
        }
    }

    // MARK: - GPG Secret Key Storage
    //
    // GPG secret keys are stored as opaque blobs under a separate
    // service so they're trivially distinguishable from SSH keys in
    // Keychain Access and so deleting one type never risks the other.
    // The blob format is whatever the import flow chose to persist —
    // ``GPGKeyManager`` currently stores the raw bytes of the parsed
    // ``OpenPGPSecretKeyImport`` re-encoded as JSON, but anything
    // opaque-to-Keychain works.

    nonisolated private let gpgSecretKeyService = "com.ghostty.gpg.secretkey"
    nonisolated private let gpgKeyMetadataService = "com.ghostty.gpg.keymetadata"

    /// Save the cleartext (but Keychain-encrypted-at-rest) GPG secret-
    /// key blob. Mirrors the ``savePrivateKey(_:identifier:storageLevel:authRequirement:)``
    /// SSH path including iCloud-sync's incompatibility with access
    /// control flags.
    func saveGPGSecretKey(
        _ keyData: Data,
        identifier: String,
        storageLevel: KeyStorageLevel,
        authRequirement: KeyAuthRequirement
    ) throws {
        let effectiveAuth = (storageLevel == .iCloudSync) ? KeyAuthRequirement.none : authRequirement

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgSecretKeyService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: keyData,
            kSecAttrAccessGroup as String: accessGroup
        ]

        switch storageLevel {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }

        if effectiveAuth != .none {
            if let accessControl = try createAccessControl(for: storageLevel, authRequirement: effectiveAuth) {
                query.removeValue(forKey: kSecAttrAccessible as String)
                query[kSecAttrAccessControl as String] = accessControl
            }
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeychainError.duplicateItem }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Load the GPG secret-key blob — biometric/passcode prompt is gated
    /// by the LAContext exactly like the SSH path.
    func loadGPGSecretKey(
        identifier: String,
        authRequirement: KeyAuthRequirement,
        context: LAContext?
    ) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgSecretKeyService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if authRequirement != .none, let laContext = context {
            query[kSecUseAuthenticationContext as String] = laContext
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.dataConversionFailed }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled:
            throw KeychainError.authenticationCancelled
        case errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteGPGSecretKey(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgSecretKeyService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Save GPG key metadata (JSON blob with no biometric gating —
    /// keygrips and fingerprints are public identifiers).
    func saveGPGKeyMetadata(
        _ metadata: Data,
        identifier: String,
        storageLevel: KeyStorageLevel
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: metadata,
            kSecAttrAccessGroup as String: accessGroup
        ]
        switch storageLevel {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeychainError.duplicateItem }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    nonisolated func loadGPGKeyMetadata(identifier: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.dataConversionFailed }
        return data
    }

    func deleteGPGKeyMetadata(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Replace the metadata payload for an existing GPG key (used for
    /// rename, storage-tier change, etc.). Storage-level / sync
    /// attributes are preserved — this is purely a data update.
    func updateGPGKeyMetadata(_ metadata: Data, identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgKeyMetadataService,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let attributes: [String: Any] = [kSecValueData as String: metadata]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// List every GPG key UUID present in the metadata store.
    nonisolated func listGPGKeyMetadataIdentifiers() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gpgKeyMetadataService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - SSH Password Storage

    private let sshPasswordService = "com.ghostty.ssh.password"
    nonisolated private let sshPasswordMetadataService = "com.ghostty.ssh.password.metadata"

    /// Saves an SSH password to the Keychain
    /// - Parameters:
    ///   - password: The password string
    ///   - connectionKey: The connection key (format: "host:port:username")
    ///   - storageLevel: Controls where/how the password is stored
    ///   - authRequirement: Controls when authentication is required
    /// - Throws: KeychainError if save fails
    func saveSSHPassword(
        _ password: String,
        connectionKey: String,
        storageLevel: KeyStorageLevel,
        authRequirement: KeyAuthRequirement
    ) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordService,
            kSecAttrAccount as String: connectionKey,
            kSecValueData as String: passwordData,
            kSecAttrAccessGroup as String: accessGroup
        ]

        // Configure storage level (accessibility and sync)
        switch storageLevel {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }

        // Add access control for biometric/passcode authentication if required
        if authRequirement != .none {
            if let accessControl = try createAccessControl(
                for: storageLevel,
                authRequirement: authRequirement
            ) {
                query.removeValue(forKey: kSecAttrAccessible as String)
                query[kSecAttrAccessControl as String] = accessControl
            }
        }

        Self.logger.debug("saveSSHPassword - ConnectionKey: \(connectionKey), StorageLevel: \(storageLevel.rawValue), AuthRequirement: \(authRequirement.rawValue)")

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            Self.logger.error("saveSSHPassword failed - Status: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Background-readability classification for a shared-Keychain credential,
    /// from the perspective of a process that cannot present authentication UI
    /// (i.e. the VPN Network Extension running in the background).
    enum BackgroundReadability {
        /// Item exists and can be read without any user interaction.
        case readable
        /// Item exists but is biometric/passcode-gated (needs interaction).
        case requiresInteraction
        /// No matching item is present in the shared Keychain.
        case notFound
    }

    /// Classifies whether a generic-password Keychain item for `service`/`account`
    /// in the shared access group can be read without user interaction — exactly
    /// what the background VPN extension can do (no `LAContext`, no prompt).
    ///
    /// Never surfaces UI: the read uses an interaction-disallowed `LAContext`, so
    /// a biometric-gated item returns `errSecInteractionNotAllowed` rather than
    /// prompting for Face ID / passcode. A `.none`-protected item returns its data.
    private func keychainBackgroundReadability(service: String, account: String) -> BackgroundReadability {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return .readable
        case errSecInteractionNotAllowed:
            return .requiresInteraction
        default:
            return .notFound
        }
    }

    /// Whether a saved SSH password for `connectionKey` can be read by the
    /// background VPN extension — it exists and is not biometric/passcode-gated.
    /// Mirrors the extension's interaction-free read in `VPNSSHConnector`, so a
    /// `true` here means the tunnel's Keychain lookup will succeed.
    func sshPasswordIsBackgroundReadable(connectionKey: String) -> Bool {
        keychainBackgroundReadability(service: sshPasswordService, account: connectionKey) == .readable
    }

    /// Whether a saved SSH private key is present but biometric/passcode-gated
    /// (so the background VPN extension's interaction-free read would fail).
    /// Returns `false` for keys that are readable or simply absent locally — the
    /// latter preserves existing behavior for cross-device / iCloud-synced keys.
    func sshPrivateKeyRequiresInteraction(keyID: UUID) -> Bool {
        keychainBackgroundReadability(service: "com.ghostty.ssh.privatekey", account: keyID.uuidString) == .requiresInteraction
    }

    /// Loads an SSH password from the Keychain
    /// - Parameters:
    ///   - connectionKey: The connection key (format: "host:port:username")
    ///   - authRequirement: The authentication requirement for this password
    ///   - context: Optional LAContext for authentication
    /// - Returns: The password string
    /// - Throws: KeychainError if load fails or authentication is cancelled/failed
    func loadSSHPassword(
        connectionKey: String,
        authRequirement: KeyAuthRequirement,
        context: LAContext?
    ) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordService,
            kSecAttrAccount as String: connectionKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        // Add authentication context if provided
        if authRequirement != .none, let laContext = context {
            query[kSecUseAuthenticationContext as String] = laContext
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataConversionFailed
            }
            return password
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled:
            throw KeychainError.authenticationCancelled
        case errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes an SSH password from the Keychain
    /// - Parameter connectionKey: The connection key
    /// - Throws: KeychainError if deletion fails
    func deleteSSHPassword(connectionKey: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordService,
            kSecAttrAccount as String: connectionKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Updates an existing SSH password in the Keychain
    /// - Parameters:
    ///   - password: The new password
    ///   - connectionKey: The connection key
    /// - Throws: KeychainError if update fails
    func updateSSHPassword(_ password: String, connectionKey: String) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordService,
            kSecAttrAccount as String: connectionKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Checks if an SSH password exists in the Keychain
    /// - Parameter connectionKey: The connection key
    /// - Returns: true if password exists
    func hasSSHPassword(connectionKey: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordService,
            kSecAttrAccount as String: connectionKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - SSH Password Metadata Storage

    /// Saves SSH password metadata to the Keychain
    /// - Parameters:
    ///   - metadata: The SSHSavedPassword metadata encoded as JSON Data
    ///   - connectionKey: The connection key
    ///   - storageLevel: Controls sync behavior
    /// - Throws: KeychainError if save fails
    func saveSSHPasswordMetadata(
        _ metadata: Data,
        connectionKey: String,
        storageLevel: KeyStorageLevel
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordMetadataService,
            kSecAttrAccount as String: connectionKey,
            kSecValueData as String: metadata,
            kSecAttrAccessGroup as String: accessGroup
        ]

        // Match sync behavior to storageLevel
        switch storageLevel {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }

        Self.logger.debug("saveSSHPasswordMetadata - ConnectionKey: \(connectionKey), StorageLevel: \(storageLevel.rawValue), Data size: \(metadata.count) bytes")

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            Self.logger.error("saveSSHPasswordMetadata failed - Status: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status != errSecDuplicateItem else {
            throw KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads SSH password metadata from the Keychain
    /// - Parameter connectionKey: The connection key
    /// - Returns: The metadata as JSON Data
    /// - Throws: KeychainError if load fails
    nonisolated func loadSSHPasswordMetadata(connectionKey: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordMetadataService,
            kSecAttrAccount as String: connectionKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        return data
    }

    /// Updates existing SSH password metadata in the Keychain
    /// - Parameters:
    ///   - metadata: The new metadata encoded as JSON Data
    ///   - connectionKey: The connection key
    /// - Throws: KeychainError if update fails
    func updateSSHPasswordMetadata(_ metadata: Data, connectionKey: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordMetadataService,
            kSecAttrAccount as String: connectionKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: metadata
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes SSH password metadata from the Keychain
    /// - Parameter connectionKey: The connection key
    /// - Throws: KeychainError if deletion fails
    func deleteSSHPasswordMetadata(connectionKey: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordMetadataService,
            kSecAttrAccount as String: connectionKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Lists all SSH password connection keys stored in the Keychain
    /// - Returns: Array of connection keys
    nonisolated func listSSHPasswordConnectionKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordMetadataService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            item[kSecAttrAccount as String] as? String
        }
    }

    /// Discovers all SSH password metadata items for sync detection
    /// - Returns: Array of tuples containing (connectionKey, metadata Data, isSynced flag)
    func discoverAllSSHPasswordMetadata() -> [(connectionKey: String, data: Data, isSynced: Bool)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshPasswordMetadataService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                return nil
            }
            let isSynced = (item[kSecAttrSynchronizable as String] as? Bool) ?? false
            return (account, data, isSynced)
        }
    }

    // MARK: - Mosh Session Credentials Storage

    private let moshSessionService = "com.rootshell.mosh.session"

    /// Saves Mosh session credentials to the Keychain
    /// - Parameters:
    ///   - credentials: The Mosh session credentials
    ///   - terminalId: The terminal UUID this session belongs to
    /// - Throws: KeychainError if save fails
    func saveMoshSessionCredentials(_ credentials: MoshSessionCredentials, terminalId: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let credentialsData = try encoder.encode(credentials)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: moshSessionService,
            kSecAttrAccount as String: terminalId.uuidString,
            kSecValueData as String: credentialsData,
            // Session credentials should be available after first unlock but not synced
            // (server is network-specific, syncing would be useless)
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        Self.logger.debug("saveMoshSessionCredentials - Terminal: \(terminalId.uuidString), Data size: \(credentialsData.count) bytes")

        var status = SecItemAdd(query as CFDictionary, nil)

        // If item already exists, update it instead
        if status == errSecDuplicateItem {
            Self.logger.debug("saveMoshSessionCredentials - Item exists, updating instead")
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: moshSessionService,
                kSecAttrAccount as String: terminalId.uuidString,
                kSecAttrAccessGroup as String: accessGroup
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: credentialsData
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        Self.logger.debug("saveMoshSessionCredentials - Status: \(status)")
        if status != errSecSuccess {
            Self.logger.error("saveMoshSessionCredentials - Error: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads Mosh session credentials from the Keychain
    /// - Parameter terminalId: The terminal UUID
    /// - Returns: The credentials if found and not expired
    /// - Throws: KeychainError if load fails
    func loadMoshSessionCredentials(terminalId: UUID) throws -> MoshSessionCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: moshSessionService,
            kSecAttrAccount as String: terminalId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MoshSessionCredentials.self, from: data)
    }

    /// Deletes Mosh session credentials from the Keychain
    /// - Parameter terminalId: The terminal UUID
    /// - Throws: KeychainError if deletion fails (except for item not found)
    func deleteMoshSessionCredentials(terminalId: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: moshSessionService,
            kSecAttrAccount as String: terminalId.uuidString,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)

        // Item not found is OK - it may have already been deleted
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }

        Self.logger.debug("deleteMoshSessionCredentials - Deleted credentials for terminal: \(terminalId.uuidString)")
    }

    /// Lists all terminal UUIDs that have stored Mosh session credentials
    /// - Returns: Array of terminal UUIDs
    func listMoshSessionTerminalIds() -> [UUID] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: moshSessionService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return UUID(uuidString: account)
        }
    }

    /// Cleans up expired Mosh session credentials (>72 hours old)
    /// Also returns the count of cleaned up sessions for logging
    /// - Returns: Number of expired credentials deleted
    @discardableResult
    func cleanupExpiredMoshSessions() -> Int {
        let terminalIds = listMoshSessionTerminalIds()
        var deletedCount = 0

        for terminalId in terminalIds {
            do {
                let credentials = try loadMoshSessionCredentials(terminalId: terminalId)
                if credentials.isExpired {
                    try deleteMoshSessionCredentials(terminalId: terminalId)
                    deletedCount += 1
                    Self.logger.info("Cleaned up expired Mosh credentials for terminal \(terminalId.uuidString) (age: \(credentials.age))")
                }
            } catch {
                // If we can't load it, try to delete it anyway (corrupted data)
                try? deleteMoshSessionCredentials(terminalId: terminalId)
                deletedCount += 1
                Self.logger.warning("Deleted unreadable Mosh credentials for terminal \(terminalId.uuidString)")
            }
        }

        if deletedCount > 0 {
            Self.logger.info("Cleaned up \(deletedCount) expired Mosh session credentials")
        }

        return deletedCount
    }

    /// Cleans up orphaned Mosh session credentials (terminals not in active window state)
    /// - Parameter activeTerminalIds: Set of terminal UUIDs that are currently in use
    /// - Returns: Number of orphaned credentials deleted
    @discardableResult
    func cleanupOrphanedMoshSessions(activeTerminalIds: Set<UUID>) -> Int {
        let storedIds = listMoshSessionTerminalIds()
        var deletedCount = 0

        for terminalId in storedIds {
            if !activeTerminalIds.contains(terminalId) {
                do {
                    try deleteMoshSessionCredentials(terminalId: terminalId)
                    deletedCount += 1
                    Self.logger.info("Cleaned up orphaned Mosh credentials for terminal \(terminalId.uuidString)")
                } catch {
                    Self.logger.warning("Failed to delete orphaned Mosh credentials: \(error.localizedDescription)")
                }
            }
        }

        if deletedCount > 0 {
            Self.logger.info("Cleaned up \(deletedCount) orphaned Mosh session credentials")
        }

        return deletedCount
    }

    // MARK: - Trzsz Session Credentials Storage

    private let trzszSessionService = "com.rootshell.trzsz.session"

    /// Saves trzsz session credentials to the Keychain
    /// - Parameters:
    ///   - credentials: The trzsz session credentials
    ///   - terminalId: The terminal UUID this session belongs to
    /// - Throws: KeychainError if save fails
    func saveTrzszSessionCredentials(_ credentials: TrzszSessionCredentials, terminalId: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let credentialsData = try encoder.encode(credentials)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trzszSessionService,
            kSecAttrAccount as String: terminalId.uuidString,
            kSecValueData as String: credentialsData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let dataSize = credentialsData.count
        Self.logger.debug("saveTrzszSessionCredentials - Terminal: \(terminalId.uuidString), Data size: \(dataSize) bytes")
        ResumeDebugLogger.shared.log("saveTrzszSessionCredentials: uuid=\(terminalId.uuidString.prefix(8)), dataSize=\(dataSize)")

        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            Self.logger.debug("saveTrzszSessionCredentials - Item exists, updating instead")
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: trzszSessionService,
                kSecAttrAccount as String: terminalId.uuidString,
                kSecAttrAccessGroup as String: accessGroup
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: credentialsData
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        Self.logger.debug("saveTrzszSessionCredentials - Status: \(status)")
        ResumeDebugLogger.shared.log("saveTrzszSessionCredentials result: OSStatus=\(status)")
        if status != errSecSuccess {
            Self.logger.error("saveTrzszSessionCredentials - Error: \(status) (\(Self.keychainErrorString(status)))")
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads trzsz session credentials from the Keychain
    /// - Parameter terminalId: The terminal UUID
    /// - Returns: The credentials if found
    /// - Throws: KeychainError if load fails
    func loadTrzszSessionCredentials(terminalId: UUID) throws -> TrzszSessionCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trzszSessionService,
            kSecAttrAccount as String: terminalId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        ResumeDebugLogger.shared.log("loadTrzszSessionCredentials: uuid=\(terminalId.uuidString.prefix(8)), OSStatus=\(status)")

        guard status == errSecSuccess else {
            ResumeDebugLogger.shared.log("loadTrzszSessionCredentials FAILED: OSStatus=\(status)")
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            ResumeDebugLogger.shared.log("loadTrzszSessionCredentials FAILED: data conversion")
            throw KeychainError.unexpectedStatus(errSecInternalError)
        }

        let dataSize = data.count
        ResumeDebugLogger.shared.log("loadTrzszSessionCredentials SUCCESS: dataSize=\(dataSize)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TrzszSessionCredentials.self, from: data)
    }

    /// Deletes trzsz session credentials from the Keychain
    /// - Parameter terminalId: The terminal UUID
    /// - Throws: KeychainError if deletion fails (except for item not found)
    func deleteTrzszSessionCredentials(terminalId: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trzszSessionService,
            kSecAttrAccount as String: terminalId.uuidString,
            kSecAttrAccessGroup as String: accessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)

        ResumeDebugLogger.shared.log("deleteTrzszSessionCredentials: uuid=\(terminalId.uuidString.prefix(8)), OSStatus=\(status)")

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }

        Self.logger.debug("deleteTrzszSessionCredentials - Deleted credentials for terminal: \(terminalId.uuidString)")
    }

    /// Lists all terminal UUIDs that have stored trzsz session credentials
    /// - Returns: Array of terminal UUIDs
    func listTrzszSessionTerminalIds() -> [UUID] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trzszSessionService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return UUID(uuidString: account)
        }
    }

    /// Purges trzsz session credentials that fail to decode (corrupt /
    /// incompatible across upgrades). Time-based eviction is intentionally
    /// NOT done here: a long-lived attachable session can have a `createdAt`
    /// arbitrarily old yet still be alive on the server. The accurate
    /// "AliveTimeout window still open?" check uses the autosaved
    /// heartbeat and lives in `TrzszSession.attemptResume`.
    /// - Returns: Number of unreadable credentials deleted
    @discardableResult
    func cleanupExpiredTrzszSessions() -> Int {
        let terminalIds = listTrzszSessionTerminalIds()
        var deletedCount = 0

        for terminalId in terminalIds {
            do {
                _ = try loadTrzszSessionCredentials(terminalId: terminalId)
            } catch {
                try? deleteTrzszSessionCredentials(terminalId: terminalId)
                deletedCount += 1
                Self.logger.warning("Deleted unreadable trzsz credentials for terminal \(terminalId.uuidString)")
            }
        }

        if deletedCount > 0 {
            Self.logger.info("Cleaned up \(deletedCount) unreadable trzsz session credentials")
        }

        return deletedCount
    }

    /// Cleans up trzsz session credentials whose terminal no longer exists in
    /// the saved window state (closed tabs, deleted windows). Should be
    /// called once at startup with the active terminal ID set after
    /// `loadSavedState` has parsed the on-disk window state.
    /// - Parameter activeTerminalIds: Set of terminal UUIDs currently in use
    /// - Returns: Number of orphaned credentials deleted
    @discardableResult
    func cleanupOrphanedTrzszSessions(activeTerminalIds: Set<UUID>) -> Int {
        let storedIds = listTrzszSessionTerminalIds()
        var deletedCount = 0

        for terminalId in storedIds {
            if !activeTerminalIds.contains(terminalId) {
                do {
                    try deleteTrzszSessionCredentials(terminalId: terminalId)
                    deletedCount += 1
                    Self.logger.info("Cleaned up orphaned trzsz credentials for terminal \(terminalId.uuidString)")
                } catch {
                    Self.logger.warning("Failed to delete orphaned trzsz credentials: \(error.localizedDescription)")
                }
            }
        }

        if deletedCount > 0 {
            Self.logger.info("Cleaned up \(deletedCount) orphaned trzsz session credentials")
        }

        return deletedCount
    }

    /// Load private key data by key ID (with biometric auth if needed).
    func loadPrivateKeyData(id: UUID) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ghostty.ssh.privatekey",
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.itemNotFound
        }
        return data
    }
}
