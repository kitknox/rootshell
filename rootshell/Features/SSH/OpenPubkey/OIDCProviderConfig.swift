import Foundation

/// An OIDC provider an OpenPubkey identity can be created against.
///
/// The built-in entries mirror opkssh's default client config: these client
/// IDs (and Google's installed-app secret) are public values published in
/// the opkssh repository, registered with localhost loopback redirect URIs.
nonisolated struct OIDCProviderConfig: Codable, Hashable, Sendable {
    /// Stable identifier: "google", "azure", "gitlab", "hello", or "custom".
    var providerID: String
    var displayName: String
    /// OIDC issuer; discovery happens at {issuer}/.well-known/openid-configuration.
    var issuer: String
    var clientID: String
    /// Public installed-app secret (Google requires one even for native apps).
    var clientSecret: String?
    /// Space-separated OIDC scopes.
    var scopes: String

    static let google = OIDCProviderConfig(
        providerID: "google",
        displayName: "Google",
        issuer: "https://accounts.google.com",
        clientID: "206584157355-7cbe4s640tvm7naoludob4ut1emii7sf.apps.googleusercontent.com",
        clientSecret: "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",
        scopes: "openid email profile"
    )

    static let azure = OIDCProviderConfig(
        providerID: "azure",
        displayName: "Microsoft",
        issuer: "https://login.microsoftonline.com/9188040d-6c67-4c5b-b112-36a304b66dad/v2.0",
        clientID: "096ce0a3-5e72-4da8-9c86-12924b294a01",
        clientSecret: nil,
        scopes: "openid profile email offline_access"
    )

    static let gitlab = OIDCProviderConfig(
        providerID: "gitlab",
        displayName: "GitLab",
        issuer: "https://gitlab.com",
        clientID: "8d8b7024572c7fd501f64374dec6bba37096783dfcd792b3988104be08cb6923",
        clientSecret: nil,
        scopes: "openid email"
    )

    static let hello = OIDCProviderConfig(
        providerID: "hello",
        displayName: "Hellō",
        issuer: "https://issuer.hello.coop",
        clientID: "app_xejobTKEsDNSRd5vofKB2iay_2rN",
        clientSecret: nil,
        scopes: "openid email"
    )

    static let builtIn: [OIDCProviderConfig] = [.google, .azure, .gitlab, .hello]

    /// SF Symbol for the provider row. Used as a fallback when no brand
    /// logo asset exists (e.g. the custom provider).
    var symbolName: String {
        switch providerID {
        case "google": return "g.circle"
        case "azure": return "m.circle"
        case "gitlab": return "chevron.up.2"
        case "hello": return "hand.wave"
        default: return "person.crop.circle.badge.questionmark"
        }
    }

    /// Asset-catalog brand logo for the provider, when one exists. Rendered
    /// in full color (`.renderingMode(.original)`) on the key detail screen;
    /// system-tinted in the sign-in menu picker.
    var logoImageName: String? {
        switch providerID {
        case "google": return "GoogleLogo"
        case "azure": return "MicrosoftLogo"
        case "gitlab": return "GitLabLogo"
        case "hello": return "HelloLogo"
        default: return nil
        }
    }
}

