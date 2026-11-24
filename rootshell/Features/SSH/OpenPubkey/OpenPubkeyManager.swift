import CryptoKit
import Foundation
import os.log

/// Errors surfaced by OpenPubkey identity management. The
/// reauthenticationRequired case is what connection paths see when the ID
/// token has expired and silent renewal was impossible or failed.
enum OpenPubkeyError: LocalizedError {
    case keyNotFound
    case notAnOpenPubkeyKey
    case keyMaterialUnavailable
    case missingSecrets
    case subjectMismatch
    case refreshedTokenMismatch
    case reauthenticationRequired(keyID: UUID, keyName: String, identity: String?)

    var errorDescription: String? {
        switch self {
        case .keyNotFound:
            return "SSH key not found"
        case .notAnOpenPubkeyKey:
            return "This key is not an OpenPubkey identity"
        case .keyMaterialUnavailable:
            return "Could not load the key material for this OpenPubkey identity"
        case .missingSecrets:
            return "OpenPubkey tokens for this key are missing from the Keychain"
        case .subjectMismatch:
            return "The refreshed token belongs to a different account; sign in again"
        case .refreshedTokenMismatch:
            return "The refreshed token doesn't match the original sign-in; sign in again"
        case .reauthenticationRequired(_, let keyName, let identity):
            let who = identity.map { " (\($0))" } ?? ""
            return "OpenPubkey certificate for '\(keyName)'\(who) has expired. Open Settings, SSH Keys, \(keyName), and sign in again."
        }
    }
}

/// Orchestrates OpenPubkey (opkssh) identities: browser sign-in, PK token
/// construction, self-signed certificate generation, silent refresh-token
/// renewal, and re-login.
@MainActor
final class OpenPubkeyManager {
    static let shared = OpenPubkeyManager()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "OpenPubkeyManager"
    )

    /// Renew when the ID token has less than this much life left, so a cert
    /// offered at connection time doesn't expire mid-handshake.
    private static let renewalBuffer: TimeInterval = 120

    /// Re-mint the ORIGINAL (sign-in) ID token once it reaches this age. The
    /// opkssh server verifies the original token, not the refreshed one: the
    /// install default policy (`MAX_AGE_24HOURS`) rejects once the original
    /// token's `iat` is older than 24h, and Google eventually rotates the
    /// original token's signing key out of its JWKS. Re-minting before the
    /// 24h wall (with margin for clock skew) keeps the cert valid on default
    /// servers and refreshes the Google `kid`. The refresh-token grant does
    /// NOT help here — it only matters for opt-in `oidc_refreshed` servers.
    /// Tuned for the 24h default; servers set to a shorter policy (e.g. `12h`)
    /// would need this lowered to be covered proactively.
    private static let maxOriginalTokenAge: TimeInterval = 20 * 3600

    private let client = OpenPubkeyClient()

    /// Renewals already in flight, so concurrent connection attempts don't
    /// race duplicate token-endpoint calls for the same key.
    private var inFlightRenewals: [UUID: Task<Void, Error>] = [:]

    /// Interactive browser re-auths already in flight, so two connection
    /// attempts using the same expired key don't open two browser sheets.
    private var inFlightReauths: [UUID: Task<Void, Error>] = [:]

    // MARK: - Identity Creation

    /// Full "Sign in with <provider>" flow: generates the ephemeral keypair
    /// (Ed25519 or ECDSA P-256), runs the browser OIDC flow with a
    /// CIC-committed nonce, builds the PK token and self-signed certificate,
    /// and stores everything as a regular SSHKey with an attached user
    /// certificate.
    func createIdentity(
        provider: OIDCProviderConfig,
        name: String,
        keyAlgorithm: OpenPubkeyKeyAlgorithm = .ed25519,
        sendAccessToken: Bool,
        storageLevel: KeyStorageLevel
    ) async throws -> SSHKey {
        let comment = "openpubkey \(provider.providerID)"
        let generated: GeneratedSSHKey
        switch keyAlgorithm {
        case .ed25519:
            generated = SSHKeyGenerator.generateEd25519(comment: comment)
        case .ecdsaP256:
            generated = SSHKeyGenerator.generateECDSAP256(comment: comment)
        }
        let parsed = try SSHKeyParser.parse(keyString: generated.privateKeyPEM, passphrase: nil)
        let ephemeralKey = try Self.ephemeralKey(from: parsed)

        // Run the browser flow BEFORE importing the key so a cancelled
        // sign-in leaves nothing behind.
        let cic = OpenPubkeyCIC.generate(for: ephemeralKey)
        let tokens = try await client.login(provider: provider, cic: cic)
        let idSegments = try OpenPubkeyJOSE.split(compactJWS: tokens.idToken)
        let claims = try OpenPubkeyJOSE.decodeIDTokenClaims(payloadB64: idSegments.payloadB64)

        let cicToken = try PKTokenBuilder.cicToken(idToken: tokens.idToken, cic: cic, key: ephemeralKey)
        let compactPKT = try PKTokenBuilder.compactPKT(idToken: tokens.idToken, cicToken: cicToken)

        let keyManager = SSHKeyManager.shared
        let key = try keyManager.importKey(
            name: name,
            keyString: generated.privateKeyPEM,
            storageLevel: storageLevel
        )

        do {
            try applyCertificate(
                keyID: key.id,
                ephemeralKey: ephemeralKey,
                compactPKT: compactPKT,
                claims: claims,
                accessToken: sendAccessToken ? tokens.accessToken : nil
            )

            keyManager.setOpenPubkeyInfo(keyID: key.id, info: OpenPubkeyInfo(
                provider: provider,
                identityEmail: claims.email ?? claims.preferredUsername,
                identitySubject: claims.subject,
                tokenExpiry: claims.expiresAt,
                sendAccessToken: sendAccessToken,
                hasRefreshToken: tokens.refreshToken != nil,
                lastLoginDate: Date()
            ))

            try saveSecrets(OpenPubkeySecrets(
                refreshToken: tokens.refreshToken,
                originalCompactPKT: compactPKT,
                accessToken: sendAccessToken ? tokens.accessToken : nil
            ), forKeyID: key.id)
        } catch {
            // Roll back the half-created identity.
            try? keyManager.deleteKey(id: key.id)
            throw error
        }

        let identity = claims.email ?? claims.subject
        Self.logger.info("Created OpenPubkey identity '\(identity)' via \(provider.providerID)")
        return key
    }

    // MARK: - Connection-Time Freshness

    /// Pre-auth checkpoint, called from `SSHConnectionHelper.buildAuthMethod`
    /// for every opkssh-key SSH bootstrap (direct SSH, Mosh, trzsz, jump hosts,
    /// shell-launched, reconnect, restore). No-op for non-OpenPubkey keys.
    ///
    /// Primary path: once the ORIGINAL sign-in token reaches
    /// ``maxOriginalTokenAge`` it re-mints a fresh one via an interactive
    /// browser sign-in, because that is what the server actually checks.
    /// Secondary path: if the original is still young but the appended ID token
    /// is near its own `exp`, it refreshes (or re-mints) to keep
    /// `oidc_refreshed` servers current. All of this runs **inline**, blocking
    /// the connection the same way a host-key prompt or OTP entry does (the
    /// connect path imposes no timeout on auth-building), so the connection
    /// proceeds with a fresh certificate instead of failing.
    ///
    /// Throws ``OpenPubkeyError/reauthenticationRequired`` only when the user
    /// cancels or the sign-in itself fails; the connect retry layer treats that
    /// as permanent (see `isPermanentConnectErrorApp`), so the connection fails
    /// cleanly instead of re-opening the browser on retry.
    func ensureFreshCertificate(forKeyID id: UUID) async throws {
        guard let key = SSHKeyManager.shared.savedKeys.first(where: { $0.id == id }),
              let info = key.openPubkeyInfo else {
            return
        }

        // PRIMARY keep-alive: re-mint the ORIGINAL sign-in token before the
        // server's max-age rejects it. The server verifies the original
        // token (its `iat` against the policy, its `kid` against Google's live
        // JWKS), NOT the refreshed token we append below — so a fresh original
        // is the only thing that actually extends a session on default
        // (`MAX_AGE_24HOURS`) servers, and it picks up a current Google `kid`.
        // `lastLoginDate` is exactly when the current original token was minted
        // (set only by sign-in / re-auth, never by the refresh grant).
        let originalAge = Date().timeIntervalSince(info.lastLoginDate)
        if originalAge >= Self.maxOriginalTokenAge {
            do {
                try await reauthenticate(keyID: id)
                return
            } catch {
                Self.logger.error("OpenPubkey re-mint failed for '\(key.name)': \(error.localizedDescription)")
                throw OpenPubkeyError.reauthenticationRequired(
                    keyID: id, keyName: key.name, identity: info.identityDisplay
                )
            }
        }

        // SECONDARY: keep the appended fresh ID token current (helps
        // `oidc_refreshed` servers and covers the ID token's own ~1h `exp`).
        // Not load-bearing on default servers, but harmless and cheap.
        guard info.tokenExpiry.timeIntervalSinceNow < Self.renewalBuffer else {
            return
        }

        // Prefer a silent refresh when a refresh token is available.
        if info.hasRefreshToken {
            do {
                try await renewCertificate(forKeyID: id)
                return
            } catch {
                Self.logger.error("Silent OpenPubkey renewal failed for '\(key.name)': \(error.localizedDescription) — falling back to re-mint")
            }
        }

        // Silent refresh isn't possible or failed: re-mint now via an
        // interactive sign-in.
        do {
            try await reauthenticate(keyID: id)
        } catch {
            Self.logger.error("Interactive OpenPubkey re-auth did not complete for '\(key.name)': \(error.localizedDescription)")
            throw OpenPubkeyError.reauthenticationRequired(
                keyID: id, keyName: key.name, identity: info.identityDisplay
            )
        }
    }

    /// Side-effect-light checkpoint for passive agent identity listing.
    /// It may use an existing refresh token to keep the appended ID token
    /// current, but never opens browser re-auth UI. Returns `false` when the
    /// current certificate would need interactive re-auth before a sign
    /// request can safely use it.
    func certificateAvailableForPassiveAgentListing(forKeyID id: UUID) async throws -> Bool {
        guard let key = SSHKeyManager.shared.savedKeys.first(where: { $0.id == id }),
              let info = key.openPubkeyInfo else {
            return true
        }

        let originalAge = Date().timeIntervalSince(info.lastLoginDate)
        guard originalAge < Self.maxOriginalTokenAge else {
            return false
        }

        guard info.tokenExpiry.timeIntervalSinceNow < Self.renewalBuffer else {
            return true
        }

        guard info.hasRefreshToken else {
            return false
        }

        do {
            try await renewCertificate(forKeyID: id)
            return true
        } catch {
            Self.logger.error("Silent OpenPubkey renewal failed for '\(key.name)': \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Silent Renewal

    /// Refresh-token renewal: gets a fresh ID token, appends it to the
    /// original compact PK token, and rebuilds the certificate with the
    /// same ephemeral key. Concurrent calls for the same key share one
    /// renewal.
    func renewCertificate(forKeyID id: UUID) async throws {
        if let existing = inFlightRenewals[id] {
            return try await existing.value
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performRenewal(keyID: id)
        }
        inFlightRenewals[id] = task
        defer { inFlightRenewals[id] = nil }
        try await task.value
    }

    private func performRenewal(keyID id: UUID) async throws {
        let keyManager = SSHKeyManager.shared
        guard let key = keyManager.savedKeys.first(where: { $0.id == id }) else {
            throw OpenPubkeyError.keyNotFound
        }
        guard var info = key.openPubkeyInfo else {
            throw OpenPubkeyError.notAnOpenPubkeyKey
        }
        var secrets = try loadSecrets(forKeyID: id)
        guard let refreshToken = secrets.refreshToken else {
            throw OpenPubkeyError.missingSecrets
        }

        let tokens = try await client.refresh(provider: info.provider, refreshToken: refreshToken)

        let freshSegments = try OpenPubkeyJOSE.split(compactJWS: tokens.idToken)
        let claims = try OpenPubkeyJOSE.decodeIDTokenClaims(payloadB64: freshSegments.payloadB64)
        guard claims.subject == info.identitySubject else {
            throw OpenPubkeyError.subjectMismatch
        }
        // Mirrors openpubkey v0.30.1's refreshed-token checks, so we never
        // ship a cert an `oidc_refreshed` server would reject.
        let original = try PKTokenBuilder.originalIDTokenClaims(compactPKT: secrets.originalCompactPKT)
        guard claims.issuer == original.issuer,
              claims.isIssued(to: info.provider.clientID),
              claims.issuedAt >= original.issuedAt else {
            throw OpenPubkeyError.refreshedTokenMismatch
        }

        let compactPKT = try PKTokenBuilder.refreshedCompactPKT(
            originalCompact: secrets.originalCompactPKT,
            freshIDToken: tokens.idToken
        )

        let ephemeralKey = try loadEphemeralKey(forKeyID: id)
        try applyCertificate(
            keyID: id,
            ephemeralKey: ephemeralKey,
            compactPKT: compactPKT,
            claims: claims,
            accessToken: info.sendAccessToken ? tokens.accessToken : nil
        )

        info.tokenExpiry = claims.expiresAt
        keyManager.setOpenPubkeyInfo(keyID: id, info: info)

        // Some providers rotate refresh tokens (GitLab); keep the newest.
        if let rotated = tokens.refreshToken {
            secrets.refreshToken = rotated
        }
        if info.sendAccessToken {
            secrets.accessToken = tokens.accessToken
        }
        try saveSecrets(secrets, forKeyID: id)

        let keyName = key.name
        Self.logger.info("Silently renewed OpenPubkey certificate for '\(keyName)'")
    }

    // MARK: - Browser Re-Login

    /// Full browser sign-in for an existing identity. Keeps the same
    /// ephemeral keypair (the key's id, fingerprint, and cached blobs stay
    /// valid); a fresh rz produces a fresh nonce, PK token, and certificate.
    /// This is the connection-time re-mint: it produces a fresh nonce-bound
    /// original token (resetting its age and picking up a current OP `kid`) so
    /// default `MAX_AGE_24HOURS` servers keep accepting the cert.
    func reauthenticate(keyID id: UUID) async throws {
        // Share one browser sign-in across concurrent callers for the same key
        // (e.g. two tabs connecting with the same expired identity, or the
        // "Sign In Again" button racing a connection attempt).
        if let existing = inFlightReauths[id] {
            return try await existing.value
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performReauthenticate(keyID: id)
        }
        inFlightReauths[id] = task
        defer { inFlightReauths[id] = nil }
        try await task.value
    }

    private func performReauthenticate(keyID id: UUID) async throws {
        let keyManager = SSHKeyManager.shared
        guard let key = keyManager.savedKeys.first(where: { $0.id == id }) else {
            throw OpenPubkeyError.keyNotFound
        }
        guard var info = key.openPubkeyInfo else {
            throw OpenPubkeyError.notAnOpenPubkeyKey
        }

        let ephemeralKey = try loadEphemeralKey(forKeyID: id)
        let cic = OpenPubkeyCIC.generate(for: ephemeralKey)
        let tokens = try await client.login(provider: info.provider, cic: cic)

        let idSegments = try OpenPubkeyJOSE.split(compactJWS: tokens.idToken)
        let claims = try OpenPubkeyJOSE.decodeIDTokenClaims(payloadB64: idSegments.payloadB64)
        guard claims.subject == info.identitySubject else {
            throw OpenPubkeyError.subjectMismatch
        }

        let cicToken = try PKTokenBuilder.cicToken(idToken: tokens.idToken, cic: cic, key: ephemeralKey)
        let compactPKT = try PKTokenBuilder.compactPKT(idToken: tokens.idToken, cicToken: cicToken)

        try applyCertificate(
            keyID: id,
            ephemeralKey: ephemeralKey,
            compactPKT: compactPKT,
            claims: claims,
            accessToken: info.sendAccessToken ? tokens.accessToken : nil
        )

        info.identityEmail = claims.email ?? claims.preferredUsername
        info.tokenExpiry = claims.expiresAt
        info.hasRefreshToken = tokens.refreshToken != nil
        info.lastLoginDate = Date()
        keyManager.setOpenPubkeyInfo(keyID: id, info: info)

        try saveSecrets(OpenPubkeySecrets(
            refreshToken: tokens.refreshToken,
            originalCompactPKT: compactPKT,
            accessToken: info.sendAccessToken ? tokens.accessToken : nil
        ), forKeyID: id)

        let keyName = key.name
        Self.logger.info("Re-authenticated OpenPubkey identity for '\(keyName)'")
    }

    // MARK: - Cleanup

    /// Removes the Keychain secrets for an identity (key deletion calls
    /// KeychainManager directly; this is for callers that have the manager).
    func deleteSecrets(forKeyID id: UUID) {
        KeychainManager.shared.deleteOpenPubkeySecrets(forKey: id.uuidString)
    }

    // MARK: - Helpers

    /// Builds the self-signed cert for the PK token and attaches it to the
    /// key through the standard certificate path (validates the embedded
    /// key matches and refreshes the parsed-cert cache).
    private func applyCertificate(
        keyID: UUID,
        ephemeralKey: OpenPubkeyEphemeralKey,
        compactPKT: String,
        claims: OpenPubkeyJOSE.IDTokenClaims,
        accessToken: String?
    ) throws {
        let output = try OpkSSHCertBuilder.buildCertificate(
            ephemeralKey: ephemeralKey,
            keyID: claims.email ?? "",
            compactPKT: compactPKT,
            accessToken: accessToken
        )
        let parsedCert = try SSHUserCertificateParser.parse(line: output.certLine)
        try SSHKeyManager.shared.attachUserCertificate(keyID: keyID, parsed: parsedCert)
    }

    /// Loads the stored ephemeral private key for JWS signing and cert
    /// re-signing, choosing the algorithm from the parsed key's type.
    /// OpenPubkey keys are passphrase-less software keys.
    private func loadEphemeralKey(forKeyID id: UUID) throws -> OpenPubkeyEphemeralKey {
        let keyData = try KeychainManager.shared.loadPrivateKey(identifier: id.uuidString)
        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw OpenPubkeyError.keyMaterialUnavailable
        }
        let parsed = try SSHKeyParser.parse(keyString: keyString, passphrase: nil)
        return try Self.ephemeralKey(from: parsed)
    }

    /// Wraps a freshly parsed software key as an ``OpenPubkeyEphemeralKey``,
    /// rejecting key types OpenPubkey can't sign with.
    private static func ephemeralKey(
        from parsed: SSHKeyParser.ParsedKey
    ) throws -> OpenPubkeyEphemeralKey {
        switch parsed.keyType {
        case .ed25519:
            guard let key = parsed.underlyingEd25519Key else {
                throw OpenPubkeyError.keyMaterialUnavailable
            }
            return .ed25519(key)
        case .ecdsaP256:
            guard let key = parsed.underlyingP256Key else {
                throw OpenPubkeyError.keyMaterialUnavailable
            }
            return .ecdsaP256(key)
        default:
            throw OpenPubkeyError.keyMaterialUnavailable
        }
    }

    private func saveSecrets(_ secrets: OpenPubkeySecrets, forKeyID id: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        // Place the secrets at the owning key's storage level so synced keys
        // can silently renew on other devices and device-only keys keep
        // their tokens out of backups.
        let storageLevel = SSHKeyManager.shared.savedKeys.first(where: { $0.id == id })?.storageLevel ?? .backupOnly
        try KeychainManager.shared.saveOpenPubkeySecrets(data, forKey: id.uuidString, storageLevel: storageLevel)
    }

    private func loadSecrets(forKeyID id: UUID) throws -> OpenPubkeySecrets {
        guard let data = KeychainManager.shared.loadOpenPubkeySecrets(forKey: id.uuidString) else {
            throw OpenPubkeyError.missingSecrets
        }
        return try JSONDecoder().decode(OpenPubkeySecrets.self, from: data)
    }
}
