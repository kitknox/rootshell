import CryptoKit
import Foundation

/// One-time tokens for step-ca JWK (password) provisioners: decrypt the
/// provisioner's JWE-wrapped private key with the password, then sign a
/// short-lived JWT that step-ca exchanges for an SSH user certificate.
nonisolated enum StepJWKToken {
    enum TokenError: LocalizedError {
        case malformedEncryptedKey
        case unsupportedEncryption(String)
        case incorrectPassword
        case unsupportedKey(String)

        var errorDescription: String? {
            switch self {
            case .malformedEncryptedKey:
                return "The provisioner's encrypted key is malformed"
            case .unsupportedEncryption(let alg):
                return "Unsupported provisioner key encryption: \(alg)"
            case .incorrectPassword:
                return "Incorrect provisioner password"
            case .unsupportedKey(let kind):
                return "Unsupported provisioner key type: \(kind)"
            }
        }
    }

    /// step-ca writes 600,000; the cap keeps a hostile CA from stalling
    /// sign-in with an unbounded derivation.
    static let maxPBKDF2Iterations: UInt32 = 5_000_000

    /// Decrypts a PBES2-HS256+A128KW / A*GCM compact JWE holding a JWK. The
    /// PBKDF2 derivation is slow by design, so it runs off the main actor.
    @concurrent
    static func decryptProvisionerKey(_ encryptedKey: String, password: String) async throws -> OpenPubkeyEphemeralKey {
        let parts = encryptedKey.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 5,
              let headerData = OpenPubkeyJOSE.base64URLDecode(String(parts[0])),
              let wrappedKey = OpenPubkeyJOSE.base64URLDecode(String(parts[1])),
              let iv = OpenPubkeyJOSE.base64URLDecode(String(parts[2])),
              let ciphertext = OpenPubkeyJOSE.base64URLDecode(String(parts[3])),
              let tag = OpenPubkeyJOSE.base64URLDecode(String(parts[4])) else {
            throw TokenError.malformedEncryptedKey
        }

        struct Header: Decodable {
            let alg: String
            let enc: String
            let p2s: String?
            let p2c: UInt32?
            let zip: String?
        }
        let header = try JSONDecoder().decode(Header.self, from: headerData)
        guard header.alg == "PBES2-HS256+A128KW" else {
            throw TokenError.unsupportedEncryption(header.alg)
        }
        guard header.enc == "A128GCM" || header.enc == "A256GCM" else {
            throw TokenError.unsupportedEncryption(header.enc)
        }
        if let zip = header.zip {
            throw TokenError.unsupportedEncryption("zip=\(zip)")
        }
        guard let p2s = header.p2s.flatMap(OpenPubkeyJOSE.base64URLDecode), let p2c = header.p2c, p2c > 0, p2c <= maxPBKDF2Iterations else {
            throw TokenError.malformedEncryptedKey
        }

        // RFC 7518 §4.8.1.1: salt = UTF8(alg) || 0x00 || p2s.
        var salt = Data(header.alg.utf8)
        salt.append(0)
        salt.append(p2s)
        let kek = try PBKDF2.sha256(password: Data(password.utf8), salt: salt, iterations: p2c, keyLength: 16)
        guard let cek = try? AESKeyUnwrap.unwrap(wrappedKey, kek: kek) else {
            throw TokenError.incorrectPassword
        }
        // RFC 7518 §5.3: the CEK size is fixed by `enc`.
        guard cek.count == (header.enc == "A128GCM" ? 16 : 32) else {
            throw TokenError.malformedEncryptedKey
        }
        // A bad IV or tag is a malformed JWE, not a wrong password.
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else {
            throw TokenError.malformedEncryptedKey
        }

        let jwkJSON: Data
        do {
            jwkJSON = try AES.GCM.open(box, using: SymmetricKey(data: cek), authenticating: Data(parts[0].utf8))
        } catch {
            throw TokenError.incorrectPassword
        }
        return try signingKey(fromJWK: jwkJSON)
    }

    /// The SSH-sign one-time token (`step ca token --ssh` shape). The sign
    /// request must repeat `keyID` and `principals`.
    static func sshSignToken(
        key: OpenPubkeyEphemeralKey,
        keyID kid: String,
        provisionerName: String,
        audience: String,
        subject: String,
        principals: [String],
        rootFingerprint: String
    ) throws -> String {
        let header: [String: Any] = ["alg": key.jwsAlg, "kid": kid, "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": provisionerName,
            "aud": audience,
            "sub": subject,
            "jti": OIDCLoginClient.randomBase64URL(byteCount: 32),
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "sha": rootFingerprint,
            "step": [
                "ssh": [
                    "certType": "user",
                    "keyID": subject,
                    "principals": principals,
                ] as [String: Any],
            ],
        ]
        let protectedB64 = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]).base64URLEncodedString()
        let payloadB64 = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).base64URLEncodedString()
        let signature = try OpenPubkeyJOSE.sign(protectedB64: protectedB64, payloadB64: payloadB64, key: key)
        return "\(protectedB64).\(payloadB64).\(signature)"
    }

    private static func signingKey(fromJWK data: Data) throws -> OpenPubkeyEphemeralKey {
        struct PrivateJWK: Decodable {
            let kty: String
            let crv: String?
            let d: String?
        }
        let jwk = try JSONDecoder().decode(PrivateJWK.self, from: data)
        guard let d = jwk.d.flatMap(OpenPubkeyJOSE.base64URLDecode) else {
            throw TokenError.unsupportedKey(jwk.kty)
        }
        switch (jwk.kty, jwk.crv) {
        case ("EC", "P-256"):
            return .ecdsaP256(try P256.Signing.PrivateKey(rawRepresentation: d))
        case ("OKP", "Ed25519"):
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: d))
        default:
            throw TokenError.unsupportedKey([jwk.kty, jwk.crv].compactMap { $0 }.joined(separator: " "))
        }
    }
}
