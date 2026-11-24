import CryptoKit
import Foundation

/// Minimal JWS/JWT plumbing for the OpenPubkey protocol.
///
/// Only what opkssh needs: splitting compact JWS tokens, decoding ID token
/// payload claims, and producing ES256 signatures over a JWS signing input.
nonisolated enum OpenPubkeyJOSE {
    enum JOSEError: LocalizedError {
        case malformedJWS
        case malformedPayload(String)

        var errorDescription: String? {
            switch self {
            case .malformedJWS:
                return "Malformed JWS token (expected 3 dot-separated segments)"
            case .malformedPayload(let detail):
                return "Malformed JWT payload: \(detail)"
            }
        }
    }

    struct JWSSegments: Sendable {
        let protectedB64: String
        let payloadB64: String
        let signatureB64: String

        var compact: String { "\(protectedB64).\(payloadB64).\(signatureB64)" }
    }

    /// Claims we care about from an OIDC ID token payload.
    struct IDTokenClaims: Sendable {
        let issuer: String
        let subject: String
        let audiences: [String]
        let authorizedParty: String?
        let expiresAt: Date
        let issuedAt: Date
        let email: String?
        let preferredUsername: String?
        let nonce: String?

        /// OIDC Core aud/azp rule, as the opkssh verifier applies it: aud must
        /// contain the client, and multi-audience tokens need a matching azp.
        func isIssued(to clientID: String) -> Bool {
            guard audiences.contains(clientID) else { return false }
            if let authorizedParty {
                return authorizedParty == clientID
            }
            return audiences.count == 1
        }
    }

    static func split(compactJWS: String) throws -> JWSSegments {
        let parts = compactJWS.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            throw JOSEError.malformedJWS
        }
        return JWSSegments(
            protectedB64: String(parts[0]),
            payloadB64: String(parts[1]),
            signatureB64: String(parts[2])
        )
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    static func decodeIDTokenClaims(payloadB64: String) throws -> IDTokenClaims {
        guard let payload = base64URLDecode(payloadB64) else {
            throw JOSEError.malformedPayload("payload is not valid base64url")
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let claims = object as? [String: Any] else {
            throw JOSEError.malformedPayload("payload is not a JSON object")
        }
        guard let iss = claims["iss"] as? String else {
            throw JOSEError.malformedPayload("missing iss claim")
        }
        guard let sub = claims["sub"] as? String else {
            throw JOSEError.malformedPayload("missing sub claim")
        }
        // aud may be a string or an array of strings
        let audiences: [String]
        if let aud = claims["aud"] as? String {
            audiences = [aud]
        } else if let audArray = claims["aud"] as? [String], !audArray.isEmpty {
            audiences = audArray
        } else {
            throw JOSEError.malformedPayload("missing aud claim")
        }
        guard let exp = claims["exp"] as? NSNumber else {
            throw JOSEError.malformedPayload("missing exp claim")
        }
        guard let iat = claims["iat"] as? NSNumber else {
            throw JOSEError.malformedPayload("missing iat claim")
        }
        return IDTokenClaims(
            issuer: iss,
            subject: sub,
            audiences: audiences,
            authorizedParty: claims["azp"] as? String,
            expiresAt: Date(timeIntervalSince1970: exp.doubleValue),
            issuedAt: Date(timeIntervalSince1970: iat.doubleValue),
            email: claims["email"] as? String,
            preferredUsername: claims["preferred_username"] as? String,
            nonce: claims["nonce"] as? String
        )
    }

    /// JWS signature over ASCII(protectedB64 + "." + payloadB64), base64url.
    /// The algorithm (ES256 / EdDSA) and signature encoding are owned by
    /// ``OpenPubkeyEphemeralKey``.
    static func sign(
        protectedB64: String,
        payloadB64: String,
        key: OpenPubkeyEphemeralKey
    ) throws -> String {
        let signingInput = Data("\(protectedB64).\(payloadB64)".utf8)
        return try key.signJWS(signingInput: signingInput)
    }
}
