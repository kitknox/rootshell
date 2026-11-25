import Foundation

/// Public metadata for a Smallstep (step-ca) identity, stored on the owning
/// ``SSHKey``. The certificate's expiry is the attached
/// ``SSHUserCertificateInfo/validBefore``; secrets live in the Keychain as
/// ``StepCASecrets``.
nonisolated struct StepCAInfo: Codable, Hashable, Sendable {
    nonisolated enum ProvisionerKind: String, Codable, Sendable {
        case oidc
        case jwk
    }

    /// CA base URL, e.g. `https://ca.example.com`.
    var caURL: String
    /// SHA-256 of the root certificate DER, lowercase hex.
    var rootFingerprint: String
    /// The pinned root; every CA request is anchored to it.
    var rootCertificateDER: Data
    /// Set when the CA was found through a hosted Smallstep team.
    var teamName: String?

    var provisionerName: String
    var provisionerKind: ProvisionerKind
    /// JWK provisioners: the provisioner key's `kid`.
    var jwkKeyID: String?
    /// OIDC provisioners: the provider, with `issuer` holding the
    /// provisioner's configuration endpoint.
    var oidcProvider: OIDCProviderConfig?
    /// OIDC provisioners: extra authorize parameters (`authParams`).
    var oidcAuthParams: [String]?
    /// OIDC provisioners: loopback host and port from `listenAddress`.
    var loopbackHost: String?
    var loopbackPort: UInt16?

    /// OIDC email, or the JWK token subject.
    var identity: String
    /// OIDC `sub`; renewals must match it.
    var identitySubject: String?
    /// Principals requested at signing (required for OIDC admins and JWK).
    var principals: [String]

    /// Last interactive sign-in (browser or password entry).
    var lastLoginDate: Date
    /// OIDC: a refresh token is stored for silent renewal.
    var hasRefreshToken: Bool
    /// JWK: the provisioner password is stored for silent renewal.
    var rememberPassword: Bool

    var canRenewSilently: Bool {
        switch provisionerKind {
        case .oidc: return hasRefreshToken
        case .jwk: return rememberPassword
        }
    }

    /// Host shown in the UI (and used as the default key name).
    var caHost: String {
        URL(string: caURL)?.host ?? caURL
    }
}

/// Keychain-only secrets for a step-ca identity (one blob per key).
nonisolated struct StepCASecrets: Codable, Sendable {
    var refreshToken: String?
    var provisionerPassword: String?
}
