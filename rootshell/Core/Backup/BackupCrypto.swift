import Foundation
import Crypto

enum BackupCrypto {

    // MARK: - Constants

    private static let magic: [UInt8] = Array("RSTLBKUP".utf8)  // 8 bytes
    private static let formatVersion: UInt16 = 1
    private static let saltSize = 32
    private static let nonceSize = 12
    private static let pbkdf2Iterations: UInt32 = 600_000
    private static let derivedKeySize = 32  // AES-256

    // Header layout:
    // [8]  magic
    // [2]  version (UInt16 BE)
    // [32] salt
    // [4]  iterations (UInt32 BE)
    // [12] nonce
    // Total header = 58 bytes
    private static let headerSize = 8 + 2 + saltSize + 4 + nonceSize

    // MARK: - Public API

    /// Encrypts a payload with password-derived AES-256-GCM and returns the complete file data.
    static func encrypt(payload: Data, password: String) throws -> Data {
        var salt = Data(count: saltSize)
        let saltResult = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltSize, $0.baseAddress!) }
        guard saltResult == errSecSuccess else {
            throw BackupError.encryptionFailed(CryptoError.randomGenerationFailed)
        }

        let key = try deriveKey(password: password, salt: salt, iterations: pbkdf2Iterations)

        let nonce = try AES.GCM.Nonce(data: generateRandomBytes(nonceSize))
        let sealedBox = try AES.GCM.seal(payload, using: key, nonce: nonce)

        // Assemble file
        var fileData = Data(capacity: headerSize + sealedBox.ciphertext.count + 16)

        // Magic
        fileData.append(contentsOf: magic)

        // Version (UInt16 BE)
        var version = formatVersion.bigEndian
        fileData.append(Data(bytes: &version, count: 2))

        // Salt
        fileData.append(salt)

        // Iterations (UInt32 BE)
        var iterations = pbkdf2Iterations.bigEndian
        fileData.append(Data(bytes: &iterations, count: 4))

        // Nonce
        fileData.append(contentsOf: nonce)

        // Ciphertext + auth tag
        fileData.append(sealedBox.ciphertext)
        fileData.append(sealedBox.tag)

        return fileData
    }

    /// Decrypts a backup file and returns the plaintext payload.
    static func decrypt(fileData: Data, password: String) throws -> Data {
        guard fileData.count > headerSize + 16 else {
            throw BackupError.invalidFileFormat
        }

        let header = try readHeader(fileData: fileData)

        guard header.version == formatVersion else {
            throw BackupError.unsupportedVersion(Int(header.version))
        }

        let key = try deriveKey(password: password, salt: header.salt, iterations: header.iterations)

        let ciphertextAndTag = fileData[fileData.startIndex.advanced(by: headerSize)...]
        guard ciphertextAndTag.count >= 16 else {
            throw BackupError.invalidFileFormat
        }

        do {
            let nonce = try AES.GCM.Nonce(data: header.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertextAndTag.dropLast(16),
                tag: ciphertextAndTag.suffix(16)
            )
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            if error is CryptoKitError {
                throw BackupError.wrongPassword
            }
            throw BackupError.decryptionFailed(error)
        }
    }

    /// Reads and validates the file header without decrypting.
    static func readManifest(fileData: Data) throws -> (version: UInt16, salt: Data, iterations: UInt32) {
        let header = try readHeader(fileData: fileData)
        return (header.version, header.salt, header.iterations)
    }

    // MARK: - Private Helpers

    private struct FileHeader {
        let version: UInt16
        let salt: Data
        let iterations: UInt32
        let nonce: Data
    }

    private static func readHeader(fileData: Data) throws -> FileHeader {
        guard fileData.count >= headerSize else {
            throw BackupError.invalidFileFormat
        }

        var offset = fileData.startIndex

        // Validate magic
        let fileMagic = Array(fileData[offset..<offset + 8])
        guard fileMagic == magic else {
            throw BackupError.invalidFileFormat
        }
        offset += 8

        // Version (UInt16 big-endian, read byte-by-byte to avoid alignment issues)
        let version = UInt16(fileData[offset]) << 8 | UInt16(fileData[offset + 1])
        offset += 2

        // Salt
        let salt = Data(fileData[offset..<offset + saltSize])
        offset += saltSize

        // Iterations (UInt32 big-endian, read byte-by-byte)
        let iterations = UInt32(fileData[offset]) << 24
            | UInt32(fileData[offset + 1]) << 16
            | UInt32(fileData[offset + 2]) << 8
            | UInt32(fileData[offset + 3])
        offset += 4

        // Nonce
        let nonce = Data(fileData[offset..<offset + nonceSize])

        return FileHeader(version: version, salt: salt, iterations: iterations, nonce: nonce)
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw BackupError.encryptionFailed(CryptoError.invalidPassword)
        }

        guard let derivedKey = try? PBKDF2.sha256(
            password: passwordData, salt: salt, iterations: iterations, keyLength: derivedKeySize
        ) else {
            throw BackupError.encryptionFailed(CryptoError.keyDerivationFailed)
        }

        return SymmetricKey(data: derivedKey)
    }

    private static func generateRandomBytes(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw CryptoError.randomGenerationFailed
        }
        return bytes
    }

    enum CryptoError: LocalizedError {
        case randomGenerationFailed
        case keyDerivationFailed
        case invalidPassword

        var errorDescription: String? {
            switch self {
            case .randomGenerationFailed: "Failed to generate random bytes"
            case .keyDerivationFailed: "Key derivation failed"
            case .invalidPassword: "Invalid password encoding"
            }
        }
    }
}
