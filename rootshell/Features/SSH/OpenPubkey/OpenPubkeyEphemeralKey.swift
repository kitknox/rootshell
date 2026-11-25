import CryptoKit
import Foundation

/// The ephemeral keypair an OpenPubkey (opkssh) identity is built around.
///
/// opkssh lets the client pick the algorithm (`opkssh login -t ecdsa|ed25519`);
/// this enum is the single place that knows how each algorithm shapes the
/// three formats that must stay byte-compatible with the Go reference:
///
///   1. the CIC `upk` JWK (whose SHA3 hash becomes the OIDC nonce),
///   2. the JWS signature over the ID-token payload, and
///   3. the self-signed SSH user certificate.
///
/// Every algorithm branch in the OpenPubkey builders funnels through here so
/// the wire details live in one auditable spot.
nonisolated enum OpenPubkeyEphemeralKey: Sendable {
    case ecdsaP256(P256.Signing.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)

    // MARK: - JOSE / CIC

    /// JOSE `alg`, used both as the CIC top-level `alg` and inside the `upk`
    /// JWK. Matches `jose.ES256` / `jose.EdDSA` in opkssh.
    var jwsAlg: String {
        switch self {
        case .ecdsaP256: return "ES256"
        case .ed25519: return "EdDSA"
        }
    }

    /// The `upk` JWK as compact JSON, fields in the exact order Go's
    /// `json.Marshal` of a `map[string]any` (alphabetical) plus jwx emit them.
    /// The CIC nonce is `SHA3-256` of the enclosing header, so this must match
    /// the verifier byte-for-byte.
    ///
    /// - ECDSA P-256: `{"alg":"ES256","crv":"P-256","kty":"EC","x":…,"y":…}`
    /// - Ed25519:     `{"alg":"EdDSA","crv":"Ed25519","kty":"OKP","x":…}` (OKP, no `y`)
    var upkJWKFragment: String {
        switch self {
        case .ecdsaP256(let key):
            // x963Representation = 0x04 || X(32) || Y(32)
            let point = key.publicKey.x963Representation
            let x = point.subdata(in: 1..<33).base64URLEncodedString()
            let y = point.subdata(in: 33..<65).base64URLEncodedString()
            return #"{"alg":"ES256","crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
        case .ed25519(let key):
            let x = key.publicKey.rawRepresentation.base64URLEncodedString()
            return #"{"alg":"EdDSA","crv":"Ed25519","kty":"OKP","x":"\#(x)"}"#
        }
    }

    /// JWS signature over `signingInput` (the ASCII `protected.payload`),
    /// base64url-nopad. ES256 is the raw 64-byte r‖s; EdDSA is the raw 64-byte
    /// Ed25519 signature (EdDSA is not pre-hashed).
    func signJWS(signingInput: Data) throws -> String {
        switch self {
        case .ecdsaP256(let key):
            return try key.signature(for: signingInput).rawRepresentation.base64URLEncodedString()
        case .ed25519(let key):
            return try key.signature(for: signingInput).base64URLEncodedString()
        }
    }

    // MARK: - SSH certificate

    /// OpenSSH certificate type string for this algorithm.
    var sshCertType: String {
        switch self {
        case .ecdsaP256: return "ecdsa-sha2-nistp256-cert-v01@openssh.com"
        case .ed25519: return "ssh-ed25519-cert-v01@openssh.com"
        }
    }

    /// Writes the algorithm-specific public-key field(s) that immediately
    /// follow the certificate nonce. ECDSA certs carry a curve-name string
    /// then the EC point; Ed25519 certs carry only the 32-byte public key.
    func writeCertPublicKey(into writer: inout SSHWireWriter) {
        switch self {
        case .ecdsaP256(let key):
            writer.writeString("nistp256")
            writer.writeString(key.publicKey.x963Representation)
        case .ed25519(let key):
            writer.writeString(key.publicKey.rawRepresentation)
        }
    }

    /// The signature-key blob (the CA key — here the ephemeral key itself),
    /// i.e. the standard SSH public-key wire encoding for this algorithm.
    var signatureKeyBlob: Data {
        var writer = SSHWireWriter()
        switch self {
        case .ecdsaP256(let key):
            writer.writeString("ecdsa-sha2-nistp256")
            writer.writeString("nistp256")
            writer.writeString(key.publicKey.x963Representation)
        case .ed25519(let key):
            writer.writeString("ssh-ed25519")
            writer.writeString(key.publicKey.rawRepresentation)
        }
        return writer.data
    }

    /// The certificate self-signature blob over `message`. ECDSA wraps the
    /// (r, s) pair as two mpints inside an inner string; Ed25519 wraps the flat
    /// 64-byte signature directly.
    func certSignatureBlob(over message: Data) throws -> Data {
        var writer = SSHWireWriter()
        switch self {
        case .ecdsaP256(let key):
            let raw = try key.signature(for: message).rawRepresentation
            var inner = SSHWireWriter()
            inner.writeMPInt(raw.prefix(32))
            inner.writeMPInt(raw.suffix(32))
            writer.writeString("ecdsa-sha2-nistp256")
            writer.writeString(inner.data)
        case .ed25519(let key):
            let signature = try key.signature(for: message)   // raw 64 bytes
            writer.writeString("ssh-ed25519")
            writer.writeString(signature)
        }
        return writer.data
    }
}

/// User-selectable ephemeral key algorithm for new OpenPubkey identities.
/// (Existing identities recover their algorithm from the stored key's type,
/// so this only drives creation.)
enum OpenPubkeyKeyAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case ed25519
    case ecdsaP256

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        }
    }
}
