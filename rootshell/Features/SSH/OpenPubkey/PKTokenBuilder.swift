import CryptoKit
import Foundation

/// Builds OpenPubkey PK tokens in the compact representation that opkssh
/// smuggles inside the `openpubkey-pkt` SSH certificate extension:
///
///     B64(payload):B64(opProtected):B64(opSig):B64(cicProtected):B64(cicSig)
///
/// optionally followed by `.` and a full 3-segment refreshed ID token. The
/// verifier splits at the FIRST dot, so a re-refresh replaces the suffix
/// rather than appending another one.
nonisolated enum PKTokenBuilder {
    enum PKTokenError: LocalizedError {
        case payloadMismatch
        case malformedCompactPKT

        var errorDescription: String? {
            switch self {
            case .payloadMismatch:
                return "CIC token payload does not match ID token payload"
            case .malformedCompactPKT:
                return "Malformed compact PK token"
            }
        }
    }

    /// Signs the ID token's payload with the ephemeral key using the CIC as
    /// the JWS protected header.
    static func cicToken(
        idToken: String,
        cic: OpenPubkeyCIC,
        key: OpenPubkeyEphemeralKey
    ) throws -> OpenPubkeyJOSE.JWSSegments {
        let idSegments = try OpenPubkeyJOSE.split(compactJWS: idToken)
        let signature = try OpenPubkeyJOSE.sign(
            protectedB64: cic.protectedB64,
            payloadB64: idSegments.payloadB64,
            key: key
        )
        return OpenPubkeyJOSE.JWSSegments(
            protectedB64: cic.protectedB64,
            payloadB64: idSegments.payloadB64,
            signatureB64: signature
        )
    }

    /// Compact PK token: shared payload first, then (protected, signature)
    /// pairs for the OP token and the CIC token, colon-separated.
    static func compactPKT(
        idToken: String,
        cicToken: OpenPubkeyJOSE.JWSSegments
    ) throws -> String {
        let idSegments = try OpenPubkeyJOSE.split(compactJWS: idToken)
        guard idSegments.payloadB64 == cicToken.payloadB64 else {
            throw PKTokenError.payloadMismatch
        }
        return [
            idSegments.payloadB64,
            idSegments.protectedB64,
            idSegments.signatureB64,
            cicToken.protectedB64,
            cicToken.signatureB64,
        ].joined(separator: ":")
    }

    /// Appends a refreshed ID token (full 3-segment compact JWS) to the
    /// original compact PK token, replacing any previously appended one.
    static func refreshedCompactPKT(
        originalCompact: String,
        freshIDToken: String
    ) throws -> String {
        // Strip a previously appended fresh token: the colon-separated part
        // never contains a dot, so everything from the first dot on is the
        // old suffix.
        let base: String
        if let dotIndex = originalCompact.firstIndex(of: ".") {
            base = String(originalCompact[..<dotIndex])
        } else {
            base = originalCompact
        }
        guard base.split(separator: ":", omittingEmptySubsequences: false).count == 5 else {
            throw PKTokenError.malformedCompactPKT
        }
        // Validate the fresh token shape before appending.
        _ = try OpenPubkeyJOSE.split(compactJWS: freshIDToken)
        return "\(base).\(freshIDToken)"
    }

    /// Claims of the original sign-in ID token (the shared first segment).
    static func originalIDTokenClaims(compactPKT: String) throws -> OpenPubkeyJOSE.IDTokenClaims {
        let base = compactPKT.prefix { $0 != "." }
        let parts = base.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5 else {
            throw PKTokenError.malformedCompactPKT
        }
        return try OpenPubkeyJOSE.decodeIDTokenClaims(payloadB64: String(parts[0]))
    }
}
