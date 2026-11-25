import CryptoKit
import Foundation

/// Errors shared by every managed certificate identity (OpenPubkey, step-ca).
/// `reauthenticationRequired` is what connection paths see when the
/// certificate is stale and neither silent renewal nor an inline sign-in
/// produced a new one; the connect retry layer treats it as permanent.
enum ManagedCertificateError: LocalizedError {
    case keyNotFound
    case keyMaterialUnavailable
    case missingSecrets
    case reauthenticationRequired(keyID: UUID, keyName: String, identity: String?, issuer: String)

    var errorDescription: String? {
        switch self {
        case .keyNotFound:
            return "SSH key not found"
        case .keyMaterialUnavailable:
            return "Could not load the key material for this identity"
        case .missingSecrets:
            return "Sign-in tokens for this key are missing from the Keychain"
        case .reauthenticationRequired(_, let keyName, let identity, let issuer):
            let who = identity.map { " (\($0))" } ?? ""
            return "\(issuer) certificate for '\(keyName)'\(who) has expired. Open Settings, SSH Keys, \(keyName), and sign in again."
        }
    }
}

/// Runs at most one operation per key at a time; concurrent callers for the
/// same key await the one already in flight (two tabs connecting with the
/// same expired identity open one browser sheet, not two).
@MainActor
final class KeyedTaskCoalescer {
    private var tasks: [UUID: Task<Void, Error>] = [:]

    func run(_ id: UUID, _ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        if let existing = tasks[id] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        tasks[id] = task
        defer { tasks[id] = nil }
        try await task.value
    }
}

/// Key and Keychain plumbing shared by the certificate identity managers.
@MainActor
enum ManagedCertificateKeys {
    struct Generated {
        let privateKeyPEM: String
        let ephemeralKey: OpenPubkeyEphemeralKey
    }

    /// Generates a fresh software keypair for a new identity.
    static func generate(_ algorithm: OpenPubkeyKeyAlgorithm, comment: String) throws -> Generated {
        let generated: GeneratedSSHKey
        switch algorithm {
        case .ed25519:
            generated = SSHKeyGenerator.generateEd25519(comment: comment)
        case .ecdsaP256:
            generated = SSHKeyGenerator.generateECDSAP256(comment: comment)
        }
        let parsed = try SSHKeyParser.parse(keyString: generated.privateKeyPEM, passphrase: nil)
        return Generated(privateKeyPEM: generated.privateKeyPEM, ephemeralKey: try ephemeralKey(from: parsed))
    }

    /// Imports the generated key, then runs `configure` (attach certificate,
    /// metadata, secrets). Any failure deletes the half-created key.
    static func importKey(
        _ generated: Generated,
        name: String,
        storageLevel: KeyStorageLevel,
        configure: (SSHKey) throws -> Void
    ) throws -> SSHKey {
        let keyManager = SSHKeyManager.shared
        let key = try keyManager.importKey(
            name: name,
            keyString: generated.privateKeyPEM,
            storageLevel: storageLevel
        )
        do {
            try configure(key)
        } catch {
            try? keyManager.deleteKey(id: key.id)
            throw error
        }
        return keyManager.savedKeys.first(where: { $0.id == key.id }) ?? key
    }

    /// Loads an identity's stored private key. Identity keys are
    /// passphrase-less software keys with no auth requirement.
    static func loadEphemeralKey(forKeyID id: UUID) throws -> OpenPubkeyEphemeralKey {
        let keyData = try KeychainManager.shared.loadPrivateKey(identifier: id.uuidString)
        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw ManagedCertificateError.keyMaterialUnavailable
        }
        let parsed = try SSHKeyParser.parse(keyString: keyString, passphrase: nil)
        return try ephemeralKey(from: parsed)
    }

    static func ephemeralKey(from parsed: SSHKeyParser.ParsedKey) throws -> OpenPubkeyEphemeralKey {
        switch parsed.keyType {
        case .ed25519:
            guard let key = parsed.underlyingEd25519Key else {
                throw ManagedCertificateError.keyMaterialUnavailable
            }
            return .ed25519(key)
        case .ecdsaP256:
            guard let key = parsed.underlyingP256Key else {
                throw ManagedCertificateError.keyMaterialUnavailable
            }
            return .ecdsaP256(key)
        default:
            throw ManagedCertificateError.keyMaterialUnavailable
        }
    }

    /// Stores the secrets blob at the owning key's storage level.
    static func saveSecrets<T: Encodable>(
        _ secrets: T,
        forKeyID id: UUID,
        service: KeychainManager.IdentitySecretsService
    ) throws {
        // A key deleted while a token request was in flight must not get
        // its credentials recreated (at a default storage level, no less).
        guard let key = SSHKeyManager.shared.savedKeys.first(where: { $0.id == id }) else {
            throw ManagedCertificateError.keyNotFound
        }
        let data = try JSONEncoder().encode(secrets)
        try KeychainManager.shared.saveIdentitySecrets(data, forKey: id.uuidString, service: service, storageLevel: key.storageLevel)
    }

    static func loadSecrets<T: Decodable>(
        _ type: T.Type,
        forKeyID id: UUID,
        service: KeychainManager.IdentitySecretsService
    ) throws -> T {
        guard let data = try KeychainManager.shared.loadIdentitySecrets(forKey: id.uuidString, service: service) else {
            throw ManagedCertificateError.missingSecrets
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Routes the connection-time and settings-time lifecycle calls to the
/// manager that owns a key's certificate. No-ops for keys without one.
@MainActor
enum ManagedCertificateIdentities {
    /// Pre-auth checkpoint for every SSH bootstrap that offers this key.
    /// May open a browser sign-in inline; throws
    /// ``ManagedCertificateError/reauthenticationRequired`` when that fails.
    static func ensureFreshCertificate(forKeyID id: UUID) async throws {
        guard let key = key(id) else { return }
        if key.openPubkeyInfo != nil {
            try await OpenPubkeyManager.shared.ensureFreshCertificate(forKeyID: id)
        } else if key.stepCAInfo != nil {
            try await StepCAManager.shared.ensureFreshCertificate(forKeyID: id)
        }
    }

    /// Passive agent listing: renews silently if it can, never opens UI.
    /// Returns false when the certificate needs an interactive sign-in.
    static func certificateAvailableForPassiveAgentListing(forKeyID id: UUID) async throws -> Bool {
        guard let key = key(id) else { return true }
        if key.openPubkeyInfo != nil {
            return try await OpenPubkeyManager.shared.certificateAvailableForPassiveAgentListing(forKeyID: id)
        } else if key.stepCAInfo != nil {
            return try await StepCAManager.shared.certificateAvailableForPassiveAgentListing(forKeyID: id)
        }
        return true
    }

    /// Silent renewal (refresh token or remembered password).
    static func renewCertificate(forKeyID id: UUID) async throws {
        guard let key = key(id) else { throw ManagedCertificateError.keyNotFound }
        if key.openPubkeyInfo != nil {
            try await OpenPubkeyManager.shared.renewCertificate(forKeyID: id)
        } else if key.stepCAInfo != nil {
            try await StepCAManager.shared.renewCertificate(forKeyID: id)
        }
    }

    /// Interactive sign-in for an existing identity; keeps the same key.
    /// `password` is only used by step-ca JWK provisioners.
    static func reauthenticate(keyID id: UUID, password: String? = nil) async throws {
        guard let key = key(id) else { throw ManagedCertificateError.keyNotFound }
        if key.openPubkeyInfo != nil {
            try await OpenPubkeyManager.shared.reauthenticate(keyID: id)
        } else if key.stepCAInfo != nil {
            try await StepCAManager.shared.reauthenticate(keyID: id, password: password)
        }
    }

    private static func key(_ id: UUID) -> SSHKey? {
        SSHKeyManager.shared.savedKeys.first(where: { $0.id == id })
    }
}

extension SSHKey {
    /// Expiry shown on the key list badge and detail screen for managed
    /// certificates.
    var managedCertificateExpiry: Date? {
        if let opk = openPubkeyInfo {
            return opk.tokenExpiry
        }
        if stepCAInfo != nil, let cert = userCertificate, cert.validBefore != .max {
            return Date(timeIntervalSince1970: TimeInterval(cert.validBefore))
        }
        return nil
    }

    /// Whether "Renew Now" can run without a browser or password prompt.
    var canRenewManagedCertificateSilently: Bool {
        if let opk = openPubkeyInfo {
            return opk.hasRefreshToken
        }
        if let step = stepCAInfo {
            return step.canRenewSilently
        }
        return false
    }
}
