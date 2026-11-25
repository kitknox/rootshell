import CommonCrypto
import Foundation

/// PBKDF2-HMAC-SHA256 over CommonCrypto, shared by backups, croc and the
/// step-ca JWK provisioner key decryption.
nonisolated enum PBKDF2 {
    struct DerivationFailed: Error {
        let status: Int32
    }

    static func sha256(password: Data, salt: Data, iterations: UInt32, keyLength: Int) throws -> Data {
        var derivedKey = Data(count: keyLength)
        let status = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            password.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw DerivationFailed(status: status)
        }
        return derivedKey
    }
}
