import Crypto
import Foundation
import os

@MainActor
final class ScrollbackEncryptionManager {
    static let shared = ScrollbackEncryptionManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "ScrollbackEncryption")

    private var cachedKey: SymmetricKey?

    private init() {}

    // MARK: - Errors

    enum ScrollbackEncryptionError: LocalizedError {
        case keyGenerationFailed
        case encryptionFailed(Error)
        case decryptionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .keyGenerationFailed:
                return "Failed to generate or retrieve scrollback encryption key"
            case .encryptionFailed(let error):
                return "Scrollback encryption failed: \(error.localizedDescription)"
            case .decryptionFailed(let error):
                return "Scrollback decryption failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Key Management

    private func getOrCreateKey() throws -> SymmetricKey {
        if let cached = cachedKey {
            return cached
        }

        // Try loading from Keychain
        if let keyData = try? KeychainManager.shared.loadScrollbackEncryptionKey() {
            let key = SymmetricKey(data: keyData)
            cachedKey = key
            Self.logger.debug("Loaded scrollback encryption key from Keychain")
            return key
        }

        // Generate new key
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        do {
            try KeychainManager.shared.saveScrollbackEncryptionKey(keyData)
        } catch {
            Self.logger.error("Failed to save scrollback encryption key: \(error.localizedDescription)")
            throw ScrollbackEncryptionError.keyGenerationFailed
        }

        cachedKey = key
        Self.logger.info("Generated and saved new scrollback encryption key")
        return key
    }

    // MARK: - Key Access

    /// Pre-fetch the encryption key on MainActor so it can be passed to background work.
    func getKey() throws -> SymmetricKey {
        return try getOrCreateKey()
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt data using a pre-fetched key. Can be called from any thread.
    nonisolated static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else {
                throw ScrollbackEncryptionError.encryptionFailed(
                    NSError(domain: "ScrollbackEncryption", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to produce combined sealed box"])
                )
            }
            return combined
        } catch let error as ScrollbackEncryptionError {
            throw error
        } catch {
            throw ScrollbackEncryptionError.encryptionFailed(error)
        }
    }

    func decrypt(_ combined: Data) throws -> Data {
        let key = try getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw ScrollbackEncryptionError.decryptionFailed(error)
        }
    }
}
