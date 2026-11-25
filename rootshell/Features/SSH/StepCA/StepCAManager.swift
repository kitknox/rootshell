import Foundation
import os.log

/// Smallstep (step-ca) identities: a software key whose short-lived SSH
/// user certificate the CA signs after an OIDC browser login or a JWK
/// provisioner password, renewed silently when a refresh token or the
/// remembered password allows.
@MainActor
final class StepCAManager {
    static let shared = StepCAManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "StepCAManager")

    /// Try a silent renewal once the certificate has less than this left, so
    /// it can't expire mid-handshake.
    private static let renewalBuffer: TimeInterval = 5 * 60

    enum StepCAError: LocalizedError {
        case notAStepCAKey
        case passwordRequired
        case usernameRequired
        case subjectMismatch
        case invalidAuthParam(String)

        var errorDescription: String? {
            switch self {
            case .notAStepCAKey:
                return "This key is not a Smallstep identity"
            case .passwordRequired:
                return "The provisioner password is required"
            case .usernameRequired:
                return "A username is required for a password provisioner"
            case .subjectMismatch:
                return "The sign-in belongs to a different account than this key"
            case .invalidAuthParam(let param):
                return "The provisioner has an invalid authParams entry: '\(param)'"
            }
        }
    }

    /// Everything needed to talk to one CA, resolved during sign-in setup.
    struct Authority: Sendable {
        let caURL: String
        let rootFingerprint: String
        let rootDER: Data
        let teamName: String?

        var host: String {
            URL(string: caURL)?.host ?? caURL
        }
    }

    private let oidc = OIDCLoginClient()
    private let renewals = KeyedTaskCoalescer()
    private let reauths = KeyedTaskCoalescer()

    // MARK: - Setup

    /// Resolves a CA from a hosted team or a URL plus fingerprint, pins its
    /// root, and lists the provisioners an SSH user login can use.
    func discover(
        teamName: String?,
        caURL: String,
        fingerprint: String
    ) async throws -> (Authority, [StepCAClient.Provisioner]) {
        var caURL = caURL
        var fingerprint = fingerprint
        if let teamName {
            (caURL, fingerprint) = try await StepCAClient.teamAuthority(team: teamName)
        }
        guard let normalized = StepCAClient.normalizedFingerprint(fingerprint) else {
            throw StepCAClient.ClientError.invalidFingerprint
        }
        let rootDER = try await StepCAClient.fetchRoot(caURL: caURL, fingerprint: normalized)
        let client = try StepCAClient(caURL: caURL, rootDER: rootDER)
        try await client.checkSupported()
        let provisioners = try await client.provisioners()
        let authority = Authority(
            caURL: client.baseURL.absoluteString,
            rootFingerprint: normalized,
            rootDER: rootDER,
            teamName: teamName
        )
        return (authority, provisioners)
    }

    /// Creates the identity: signs in (browser or password), has the CA sign
    /// a fresh key, and stores it with the certificate attached. Nothing is
    /// saved if sign-in or signing fails.
    func createIdentity(
        authority: Authority,
        provisioner: StepCAClient.Provisioner,
        password: String?,
        rememberPassword: Bool,
        jwkSubject: String?,
        name: String,
        keyAlgorithm: OpenPubkeyKeyAlgorithm,
        storageLevel: KeyStorageLevel
    ) async throws -> SSHKey {
        guard let kind = provisioner.kind else { throw StepCAClient.ClientError.noUsableProvisioners }
        let client = try StepCAClient(caURL: authority.caURL, rootDER: authority.rootDER)
        let generated = try ManagedCertificateKeys.generate(keyAlgorithm, comment: "step \(provisioner.name)")

        var info = StepCAInfo(
            caURL: authority.caURL,
            rootFingerprint: authority.rootFingerprint,
            rootCertificateDER: authority.rootDER,
            teamName: authority.teamName,
            provisionerName: provisioner.name,
            provisionerKind: kind,
            jwkKeyID: provisioner.keyID,
            oidcProvider: provisioner.oidcProvider,
            oidcAuthParams: provisioner.authParams,
            loopbackHost: provisioner.loopbackHost,
            loopbackPort: provisioner.loopbackPort,
            identity: "",
            identitySubject: nil,
            principals: [],
            lastLoginDate: Date(),
            hasRefreshToken: false,
            rememberPassword: false
        )
        var secrets = StepCASecrets()

        let ott: String
        switch kind {
        case .oidc:
            let signIn = try await signInWithBrowser(info: info)
            info.identity = signIn.identity
            info.identitySubject = signIn.subject
            info.principals = Self.oidcPrincipals(forIdentity: signIn.identity)
            info.hasRefreshToken = signIn.refreshToken != nil
            secrets.refreshToken = signIn.refreshToken
            ott = signIn.idToken
        case .jwk:
            guard let password, !password.isEmpty else { throw StepCAError.passwordRequired }
            let subject = jwkSubject?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !subject.isEmpty else { throw StepCAError.usernameRequired }
            info.identity = subject
            info.principals = [subject]
            info.rememberPassword = rememberPassword
            if rememberPassword {
                secrets.provisionerPassword = password
            }
            ott = try await jwkToken(info: info, client: client, password: password, provisioner: provisioner)
        }

        let certLine = try await client.signUserCertificate(
            publicKeyBlob: generated.ephemeralKey.signatureKeyBlob,
            ott: ott,
            keyID: info.identity,
            principals: info.principals
        )

        // The user may have left the sheet while the CA was answering.
        try Task.checkCancellation()
        let finalInfo = info
        let finalSecrets = secrets
        let key = try ManagedCertificateKeys.importKey(generated, name: name, storageLevel: storageLevel) { key in
            try attachCertificate(certLine, keyID: key.id)
            SSHKeyManager.shared.setStepCAInfo(keyID: key.id, info: finalInfo)
            try ManagedCertificateKeys.saveSecrets(finalSecrets, forKeyID: key.id, service: .stepCA)
        }
        Self.logger.info("Created step-ca identity via provisioner '\(provisioner.name, privacy: .public)'")
        return key
    }

    // MARK: - Connection-Time Freshness

    /// Near expiry, renews silently when possible; a certificate that is
    /// still valid keeps being offered if that isn't possible. Once it has
    /// expired (or is missing), OIDC identities sign in again in the browser
    /// inline; JWK identities without a remembered password can't prompt
    /// here and fail with `reauthenticationRequired`.
    func ensureFreshCertificate(forKeyID id: UUID) async throws {
        guard let key = key(id), let info = key.stepCAInfo, needsRenewal(key) else { return }

        if info.canRenewSilently {
            do {
                try await renewCertificate(forKeyID: id)
                return
            } catch {
                Self.logger.error("Silent step-ca renewal failed for '\(key.name)': \(error.localizedDescription)")
            }
        }

        // Re-read: the key may have been deleted or re-signed meanwhile.
        guard let current = self.key(id), current.stepCAInfo != nil, needsRenewal(current) else { return }
        guard !hasValidCertificate(current) else { return }

        do {
            guard info.provisionerKind == .oidc else { throw StepCAError.passwordRequired }
            try await reauthenticate(keyID: id, password: nil)
        } catch {
            Self.logger.error("Interactive step-ca sign-in did not complete for '\(key.name)': \(error.localizedDescription)")
            throw ManagedCertificateError.reauthenticationRequired(
                keyID: id, keyName: key.name, identity: info.identity, issuer: "Smallstep"
            )
        }
    }

    /// Passive agent listing: silent renewal only; a still-valid certificate
    /// stays listed when that isn't possible.
    func certificateAvailableForPassiveAgentListing(forKeyID id: UUID) async throws -> Bool {
        guard let key = key(id), let info = key.stepCAInfo else { return true }
        guard needsRenewal(key) else { return hasValidCertificate(key) }
        if info.canRenewSilently {
            do {
                try await renewCertificate(forKeyID: id)
                return true
            } catch {
                Self.logger.error("Silent step-ca renewal failed for '\(key.name)': \(error.localizedDescription)")
            }
        }
        return self.key(id).map(hasValidCertificate) ?? false
    }

    // MARK: - Renewal

    /// Silent renewal with the stored refresh token or provisioner password.
    func renewCertificate(forKeyID id: UUID) async throws {
        try await renewals.run(id) { [weak self] in
            try await self?.performRenewal(keyID: id)
        }
    }

    private func performRenewal(keyID id: UUID) async throws {
        guard let key = key(id) else { throw ManagedCertificateError.keyNotFound }
        guard let info = key.stepCAInfo else { throw StepCAError.notAStepCAKey }
        // An interactive sign-in that lands while this renewal is suspended
        // bumps lastLoginDate; this renewal must not write over it.
        let loginAtStart = info.lastLoginDate
        func isStale() -> Bool {
            self.key(id)?.stepCAInfo?.lastLoginDate != loginAtStart
        }
        var secrets = try ManagedCertificateKeys.loadSecrets(StepCASecrets.self, forKeyID: id, service: .stepCA)
        let client = try StepCAClient(caURL: info.caURL, rootDER: info.rootCertificateDER)

        let ott: String
        switch info.provisionerKind {
        case .oidc:
            guard let provider = info.oidcProvider, let refreshToken = secrets.refreshToken else {
                throw ManagedCertificateError.missingSecrets
            }
            let tokens = try await oidc.refresh(provider: provider, refreshToken: refreshToken)
            let claims = try Self.claims(of: tokens.idToken)
            if let subject = info.identitySubject, claims.subject != subject {
                throw StepCAError.subjectMismatch
            }
            if isStale() { return }
            // The provider may already have invalidated the old token; keep
            // the rotated one even if the CA call below fails.
            if let rotated = tokens.refreshToken, rotated != refreshToken {
                secrets.refreshToken = rotated
                try ManagedCertificateKeys.saveSecrets(secrets, forKeyID: id, service: .stepCA)
            }
            ott = tokens.idToken
        case .jwk:
            guard let password = secrets.provisionerPassword else { throw ManagedCertificateError.missingSecrets }
            ott = try await jwkToken(info: info, client: client, password: password)
        }

        let certLine = try await sign(keyID: id, info: info, client: client, ott: ott)
        guard !isStale(), var current = self.key(id)?.stepCAInfo else { return }
        try attachCertificate(certLine, keyID: id)
        current.hasRefreshToken = secrets.refreshToken != nil
        SSHKeyManager.shared.setStepCAInfo(keyID: id, info: current)
        Self.logger.info("Silently renewed step-ca certificate for '\(key.name)'")
    }

    // MARK: - Interactive Sign-In

    /// Browser sign-in (OIDC) or password entry (JWK) for an existing
    /// identity. Keeps the same key; the CA signs a new certificate. A JWK
    /// `password` replaces the remembered one once the CA accepts it.
    func reauthenticate(keyID id: UUID, password: String?) async throws {
        try await reauths.run(id) { [weak self] in
            try await self?.performReauthenticate(keyID: id, password: password)
        }
    }

    private func performReauthenticate(keyID id: UUID, password: String?) async throws {
        guard let key = key(id) else { throw ManagedCertificateError.keyNotFound }
        guard var info = key.stepCAInfo else { throw StepCAError.notAStepCAKey }
        var secrets = (try? ManagedCertificateKeys.loadSecrets(StepCASecrets.self, forKeyID: id, service: .stepCA)) ?? StepCASecrets()
        let client = try StepCAClient(caURL: info.caURL, rootDER: info.rootCertificateDER)
        var receivedRefreshToken = false

        let ott: String
        switch info.provisionerKind {
        case .oidc:
            let signIn = try await signInWithBrowser(info: info)
            if let subject = info.identitySubject, signIn.subject != subject {
                throw StepCAError.subjectMismatch
            }
            info.identity = signIn.identity
            info.principals = Self.oidcPrincipals(forIdentity: signIn.identity)
            // Providers often skip the refresh token once consent exists;
            // keep the one we have rather than losing silent renewal.
            if let refreshToken = signIn.refreshToken {
                secrets.refreshToken = refreshToken
                receivedRefreshToken = true
            }
            info.hasRefreshToken = secrets.refreshToken != nil
            ott = signIn.idToken
        case .jwk:
            guard let password = password ?? secrets.provisionerPassword, !password.isEmpty else {
                throw StepCAError.passwordRequired
            }
            ott = try await jwkToken(info: info, client: client, password: password)
            if info.rememberPassword {
                secrets.provisionerPassword = password
            }
        }

        try attachCertificate(try await sign(keyID: id, info: info, client: client, ott: ott), keyID: id)
        // A silent renewal may have rotated the refresh token while the
        // browser was open; don't write back the copy read before it.
        if info.provisionerKind == .oidc, !receivedRefreshToken,
           let current = try? ManagedCertificateKeys.loadSecrets(StepCASecrets.self, forKeyID: id, service: .stepCA) {
            secrets.refreshToken = current.refreshToken
            info.hasRefreshToken = current.refreshToken != nil
        }
        info.lastLoginDate = Date()
        SSHKeyManager.shared.setStepCAInfo(keyID: id, info: info)
        try ManagedCertificateKeys.saveSecrets(secrets, forKeyID: id, service: .stepCA)
        Self.logger.info("Re-authenticated step-ca identity for '\(key.name)'")
    }

    // MARK: - Host Trust

    /// Trusts the CA's SSH host keys for the given hostname patterns. A key
    /// that is already trusted keeps its patterns and gains the requested
    /// ones, so a second sign-in can widen scope but never silently ignore it.
    func trustHostKeys(authority: Authority, hostPatterns: [String]) async throws {
        let client = try StepCAClient(caURL: authority.caURL, rootDER: authority.rootDER)
        let hostKeys = try await client.sshHostCAKeys()
        try Task.checkCancellation()
        let manager = HostCAManager.shared
        for line in hostKeys {
            try manager.addOrExtendCA(name: "Smallstep \(authority.host)", openSSHPublicKey: line, hostPatterns: hostPatterns)
        }
    }

    // MARK: - Helpers

    private struct BrowserSignIn {
        let idToken: String
        let refreshToken: String?
        let identity: String
        let subject: String
    }

    private func signInWithBrowser(info: StepCAInfo) async throws -> BrowserSignIn {
        guard let provider = info.oidcProvider else { throw StepCAClient.ClientError.noUsableProvisioners }
        var params: [URLQueryItem] = []
        for pair in info.oidcAuthParams ?? [] {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else {
                throw StepCAError.invalidAuthParam(pair)
            }
            params.append(URLQueryItem(name: name, value: parts.count > 1 ? parts[1] : nil))
        }
        // `access_type=offline` asks Google for a refresh token (others
        // ignore it), unless the provisioner already sets it.
        if !params.contains(where: { $0.name == "access_type" }) {
            params.append(URLQueryItem(name: "access_type", value: "offline"))
        }
        let tokens = try await oidc.login(
            provider: provider,
            nonce: OIDCLoginClient.randomBase64URL(byteCount: 32),
            redirect: .stepCA(host: info.loopbackHost, port: info.loopbackPort),
            extraAuthParams: params
        )
        let claims = try Self.claims(of: tokens.idToken)
        return BrowserSignIn(
            idToken: tokens.idToken,
            refreshToken: tokens.refreshToken,
            identity: claims.email ?? claims.preferredUsername ?? claims.subject,
            subject: claims.subject
        )
    }

    /// The principals step-ca's default identity function grants an OIDC
    /// email (sanitized local part, raw local part, email). Non-admins get
    /// these regardless; provisioner admins must request them explicitly.
    static func oidcPrincipals(forIdentity email: String) -> [String] {
        let local = email.split(separator: "@", omittingEmptySubsequences: false).dropLast().joined(separator: "@")
        guard !local.isEmpty else { return [email] }
        let sanitized = String(local.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            switch scalar {
            case "a"..."z", "0"..."9", "-": return Character(scalar)
            case ".": return nil
            default: return "_"
            }
        })
        var seen = Set<String>()
        return [sanitized, local, email].filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `provisioner` skips the provisioner list lookup when the caller has it.
    private func jwkToken(
        info: StepCAInfo,
        client: StepCAClient,
        password: String,
        provisioner known: StepCAClient.Provisioner? = nil
    ) async throws -> String {
        guard let kid = info.jwkKeyID else { throw StepCAClient.ClientError.missingProvisionerKey }
        var provisioner = known
        if provisioner == nil {
            provisioner = try await client.provisioners().first { $0.kind == .jwk && $0.name == info.provisionerName && $0.keyID == kid }
        }
        guard let provisioner else { throw StepCAClient.ClientError.noUsableProvisioners }
        let encrypted = try await client.encryptedKey(provisioner: provisioner)
        let signingKey = try await StepJWKToken.decryptProvisionerKey(encrypted, password: password)
        return try StepJWKToken.sshSignToken(
            key: signingKey,
            keyID: kid,
            provisionerName: info.provisionerName,
            audience: client.sshSignAudience,
            subject: info.identity,
            principals: info.principals,
            rootFingerprint: info.rootFingerprint
        )
    }

    /// Has the CA sign the key; returns the certificate line without
    /// attaching it, so callers can drop a stale result.
    /// Has the CA sign the key; returns the certificate line without
    /// attaching it, so callers can drop a stale result.
    private func sign(keyID id: UUID, info: StepCAInfo, client: StepCAClient, ott: String) async throws -> String {
        // The CA only needs the public key; reading the private key here
        // could prompt for biometrics during passive agent listing.
        guard let cachedBlob = key(id)?.publicKeyBlob else {
            throw ManagedCertificateError.keyMaterialUnavailable
        }
        return try await client.signUserCertificate(
            publicKeyBlob: SSHUserCertificateParser.normalizedCachedBlob(cachedBlob),
            ott: ott,
            keyID: info.identity,
            principals: info.principals
        )
    }

    private func attachCertificate(_ certLine: String, keyID: UUID) throws {
        let parsed = try SSHUserCertificateParser.parse(line: certLine)
        try SSHKeyManager.shared.attachUserCertificate(keyID: keyID, parsed: parsed)
    }

    private func needsRenewal(_ key: SSHKey) -> Bool {
        guard let cert = key.userCertificate else { return true }
        if cert.isNotYetValid { return false }
        guard cert.validBefore != .max else { return false }
        return Double(cert.validBefore) - Date().timeIntervalSince1970 < Self.renewalBuffer
    }

    private func hasValidCertificate(_ key: SSHKey) -> Bool {
        guard let cert = key.userCertificate else { return false }
        return !cert.isExpired && !cert.isNotYetValid
    }

    private func key(_ id: UUID) -> SSHKey? {
        SSHKeyManager.shared.savedKeys.first(where: { $0.id == id })
    }

    private static func claims(of idToken: String) throws -> OpenPubkeyJOSE.IDTokenClaims {
        let segments = try OpenPubkeyJOSE.split(compactJWS: idToken)
        return try OpenPubkeyJOSE.decodeIDTokenClaims(payloadB64: segments.payloadB64)
    }
}
