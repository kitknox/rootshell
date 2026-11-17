// WeatherCredentials.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import Security

/// API keys for weather providers that need one, one keychain item per
/// provider. Synced through iCloud Keychain like the AI provider keys, so
/// every device that syncs the setting also has the key.
nonisolated enum WeatherCredentials {
    struct KeychainError: Error { let status: OSStatus }

    private static let service = "com.rootshell.weather.apikey"

    static func apiKey(for provider: WeatherProviderID) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Replaces the provider's key; nil or blank removes it.
    static func setAPIKey(_ key: String?, for provider: WeatherProviderID) throws {
        let removed = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw KeychainError(status: removed) }
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var item = baseQuery(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrSynchronizable as String] = true
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    private static func baseQuery(_ provider: WeatherProviderID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue,
         kSecAttrAccessGroup as String: AppIdentifiers.keychainAccessGroup,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }
}
#endif
