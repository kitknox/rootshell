#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Crypto
import Citadel
import Observation
import os.log

/// One connection's session-bind@openssh.com records, checked as OpenSSH's ssh-agent does
/// (process_ext_session_bind): the host key must have signed the session ID, nothing may
/// follow an authentication bind, and at most 16 are kept.
nonisolated struct LocalAgentSessionBinds: Sendable {
    private struct Bind: Sendable {
        var hostKeyBlob: Data
        var sessionID: Data
        var isForwarding: Bool
    }

    private var binds: [Bind] = []

    /// The first hop: the host the connecting client itself reached. Later hops, sent through a
    /// forwarded agent, can't replace it.
    var first: (hostKeyBlob: Data, isForwarding: Bool)? {
        binds.first.map { ($0.hostKeyBlob, $0.isForwarding) }
    }

    mutating func record(hostKeyBlob: Data, sessionID: Data, signature: Data, isForwarding: Bool) -> Bool {
        guard Self.signatureIsValid(hostKeyBlob: hostKeyBlob, sessionID: sessionID, signature: signature) else {
            return false
        }
        for bind in binds {
            // A socket bound for authentication takes no further binds.
            guard bind.isForwarding else { return false }
            if bind.sessionID == sessionID {
                return bind.hostKeyBlob == hostKeyBlob
            }
        }
        guard binds.count < SSHAgentWireCodec.maxSessionBinds else { return false }
        binds.append(Bind(hostKeyBlob: hostKeyBlob, sessionID: sessionID, isForwarding: isForwarding))
        return true
    }

    private static func signatureIsValid(hostKeyBlob: Data, sessionID: Data, signature: Data) -> Bool {
        // RSA host keys parse through Citadel's types, which a Citadel connection may not have registered yet.
        NIOSSHAlgorithms.register(
            publicKey: Insecure.RSA.PublicKey.self,
            // OpenSSH clients usually sign their KEX (hence the bind) with rsa-sha2-512.
            signatures: [Insecure.RSA.Signature.self, Insecure.RSA.SHA1Signature.self, Insecure.RSA.SHA512Signature.self]
        )
        guard let hostKey = try? NIOSSHPublicKey(sshWireBlob: ByteBuffer(data: hostKeyBlob)) else {
            return false
        }
        return hostKey.isValidSignature(sshWireSignature: ByteBuffer(data: signature), for: ByteBuffer(data: sessionID))
    }
}

nonisolated struct LocalAgentBoundDestination: Sendable, Equatable {
    var hostKeyBlob: Data
    var isForwarding: Bool
    var fingerprint: String
    var knownHostName: String?

    var displayName: String {
        knownHostName ?? fingerprint
    }
}

nonisolated struct LocalAgentClientGateDecision: Sendable, Equatable {
    var generation: Int
    var allowed: Bool
    var rule: LocalAgentClientRule?
}

nonisolated struct LocalAgentHandleResult: Sendable {
    var frame: Data
    var clientGate: LocalAgentClientGateDecision?
}

nonisolated private struct LocalAgentEphemeralIdentity: Identifiable, Sendable {
    var id: UUID
    var publicKeyBlob: Data
    var comment: String
    var keyType: SSHKey.KeyType
    var keyVariant: SSHPrivateKeyVariant
    var confirmRequired: Bool
    var expiresAt: Date?
}

nonisolated private struct LocalAgentSignatureApprovalKey: Hashable, Sendable {
    var keyID: UUID
    var clientIdentity: String
    var destinationFingerprint: String?
    var isForwarding: Bool?

    init(keyID: UUID, peer: LocalAgentPeerIdentity, destination: LocalAgentBoundDestination?) {
        self.keyID = keyID
        self.clientIdentity = peer.ruleKey?.description ?? "pid:\(peer.pid):path:\(peer.path)"
        self.destinationFingerprint = destination?.fingerprint
        self.isForwarding = destination?.isForwarding
    }
}

@MainActor
@Observable
final class LocalSSHAgentManager {
    static let shared = LocalSSHAgentManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "LocalAgent")

    let policyStore = LocalAgentPolicyStore.shared
    let auditLog = LocalAgentAuditLog.shared

    private let keyManager = SSHKeyManager.shared
    private let signer: SSHAgentSigner
    private var server: LocalSSHAgentServer!
    private var pendingContinuations: [UUID: CheckedContinuation<LocalAgentApprovalRequest.Decision, Never>] = [:]
    private var sessionApprovedClients: Set<LocalAgentClientKey> = []
    private var sessionApprovedSignatures: Set<LocalAgentSignatureApprovalKey> = []
    private var ephemeralIdentities: [LocalAgentEphemeralIdentity] = []
    private var lockDigest: SHA256.Digest?
    private var rulesGeneration = 0
    private(set) var isRunning = false

    var socketPath: String? {
        Self.socketPath()
    }

    var config: LocalAgentConfig {
        policyStore.config
    }

    var exposedEphemeralIdentities: [String] {
        ephemeralIdentities.map { identity in
            if let expiresAt = identity.expiresAt {
                return "\(identity.comment) (expires \(expiresAt.formatted(date: .omitted, time: .shortened)))"
            }
            return identity.comment
        }
    }

    private init() {
        self.signer = SSHAgentSigner(keyManager: keyManager)
        self.server = LocalSSHAgentServer(manager: self)
    }

    nonisolated static var activeSocketPathForShells: String? {
        LocalAgentPolicyStore.activeSocketPathFromDefaults()
    }

    static func socketPath() -> String? {
        AppGroupHelper.containerURL?.appendingPathComponent("agent.sock").path
    }

    func startIfEnabled() {
        guard config.enabled, let path = socketPath else {
            stop()
            return
        }
        guard !isRunning else { return }
        isRunning = true
        server.start(path: path)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        server.stop(unlinkPath: socketPath)
    }

    func configDidChange() {
        if config.enabled {
            startIfEnabled()
        } else {
            stop()
        }
        invalidateClientGateCache()
    }

    func invalidateClientGateCache() {
        rulesGeneration += 1
    }

    func resetSessionApprovals() {
        sessionApprovedClients.removeAll()
        sessionApprovedSignatures.removeAll()
    }

    func handle(
        request: SSHAgentWireCodec.Request,
        peer: LocalAgentPeerIdentity,
        destination: LocalAgentBoundDestination?,
        cachedGate: LocalAgentClientGateDecision?
    ) async -> LocalAgentHandleResult {
        if case .sessionBind = request {
            audit(peer: peer, action: .sessionBind, destination: destination, outcome: .allowed)
            return LocalAgentHandleResult(frame: SSHAgentWireCodec.successFrame, clientGate: cachedGate)
        }

        if lockDigest != nil, let frame = SSHAgentWireCodec.responseWhileLocked(to: request) {
            audit(peer: peer, action: action(for: request), destination: destination, outcome: .denied, detail: "agent locked")
            return LocalAgentHandleResult(frame: frame, clientGate: cachedGate)
        }

        let gate = await clientGate(peer: peer, cached: cachedGate)
        guard gate.allowed else {
            audit(peer: peer, action: action(for: request), destination: destination, outcome: .denied)
            let frame: Data
            if case .listIdentities = request {
                frame = SSHAgentWireCodec.identitiesAnswer([])
            } else {
                frame = SSHAgentWireCodec.failureFrame
            }
            return LocalAgentHandleResult(frame: frame, clientGate: gate)
        }

        // Approval may suspend while another connection locks the agent.
        if lockDigest != nil, let frame = SSHAgentWireCodec.responseWhileLocked(to: request) {
            return LocalAgentHandleResult(frame: frame, clientGate: gate)
        }

        if let ruleKey = peer.ruleKey {
            policyStore.noteUsed(key: ruleKey, path: peer.path.isEmpty ? nil : peer.path)
        }

        switch request {
        case .listIdentities:
            let frame = await listIdentities(rule: gate.rule, peer: peer, destination: destination)
            audit(peer: peer, action: .list, destination: destination, outcome: .allowed)
            return LocalAgentHandleResult(frame: frame, clientGate: gate)

        case .sign(let keyBlob, let data, let flags):
            let frame = await sign(
                keyBlob: keyBlob,
                data: data,
                flags: flags,
                peer: peer,
                destination: destination,
                rule: gate.rule
            )
            return LocalAgentHandleResult(frame: frame, clientGate: gate)

        case .addIdentity(let identity, let constraints):
            let frame = await addIdentity(identity, constraints: constraints, peer: peer)
            return LocalAgentHandleResult(frame: frame, clientGate: gate)

        case .removeIdentity(let keyBlob):
            let removed = removeIdentity(keyBlob: keyBlob)
            audit(peer: peer, action: .remove, outcome: removed ? .allowed : .failed)
            return LocalAgentHandleResult(frame: removed ? SSHAgentWireCodec.successFrame : SSHAgentWireCodec.failureFrame, clientGate: gate)

        case .removeAll:
            ephemeralIdentities.removeAll()
            audit(peer: peer, action: .remove, outcome: .allowed, detail: "removed ephemeral identities")
            return LocalAgentHandleResult(frame: SSHAgentWireCodec.successFrame, clientGate: gate)

        case .lock(let passphrase):
            lockDigest = SHA256.hash(data: passphrase)
            resetSessionApprovals()
            audit(peer: peer, action: .lock, outcome: .allowed)
            return LocalAgentHandleResult(frame: SSHAgentWireCodec.successFrame, clientGate: gate)

        case .unlock(let passphrase):
            guard let lockDigest, SHA256.hash(data: passphrase) == lockDigest else {
                audit(peer: peer, action: .unlock, outcome: .denied)
                return LocalAgentHandleResult(frame: SSHAgentWireCodec.failureFrame, clientGate: gate)
            }
            self.lockDigest = nil
            audit(peer: peer, action: .unlock, outcome: .allowed)
            return LocalAgentHandleResult(frame: SSHAgentWireCodec.successFrame, clientGate: gate)

        case .unsupported:
            return LocalAgentHandleResult(frame: SSHAgentWireCodec.failureFrame, clientGate: gate)

        case .sessionBind:
            return LocalAgentHandleResult(frame: SSHAgentWireCodec.successFrame, clientGate: gate)
        }
    }

    func makeBoundDestination(hostKeyBlob: Data, isForwarding: Bool) -> LocalAgentBoundDestination {
        let fingerprint = Self.fingerprint(for: hostKeyBlob)
        let hostName = KnownHostsManager.shared.allHosts.first { known in
            guard let knownBlob = Data(base64Encoded: known.publicKeyData) else { return false }
            return knownBlob == hostKeyBlob || known.fullFingerprint == fingerprint
        }?.displayName
        return LocalAgentBoundDestination(
            hostKeyBlob: hostKeyBlob,
            isForwarding: isForwarding,
            fingerprint: fingerprint,
            knownHostName: hostName
        )
    }

    private func clientGate(
        peer: LocalAgentPeerIdentity,
        cached: LocalAgentClientGateDecision?
    ) async -> LocalAgentClientGateDecision {
        if let cached, cached.generation == rulesGeneration {
            return cached
        }

        guard let ruleKey = peer.ruleKey else {
            let decision = await requestApproval(
                subject: .client,
                peer: peer,
                destination: nil,
                canPersist: false
            )
            return LocalAgentClientGateDecision(
                generation: rulesGeneration,
                allowed: decision == .allowOnce || decision == .allowSession || decision == .alwaysAllow,
                rule: nil
            )
        }

        if sessionApprovedClients.contains(ruleKey) {
            return LocalAgentClientGateDecision(generation: rulesGeneration, allowed: true, rule: policyStore.rule(for: ruleKey))
        }

        if let rule = policyStore.rule(for: ruleKey) {
            switch rule.policy {
            case .allow:
                return LocalAgentClientGateDecision(generation: rulesGeneration, allowed: true, rule: rule)
            case .deny:
                return LocalAgentClientGateDecision(generation: rulesGeneration, allowed: false, rule: rule)
            case .askSession, .askAlways:
                let decision = await requestApproval(subject: .client, peer: peer, destination: nil, canPersist: true)
                applyClientDecision(decision, peer: peer, ruleKey: ruleKey, existingRule: rule)
                let allowed = decision == .allowOnce || decision == .allowSession || decision == .alwaysAllow
                return LocalAgentClientGateDecision(generation: rulesGeneration, allowed: allowed, rule: policyStore.rule(for: ruleKey))
            }
        }

        let decision = await requestApproval(subject: .client, peer: peer, destination: nil, canPersist: true)
        applyClientDecision(decision, peer: peer, ruleKey: ruleKey, existingRule: nil)
        let allowed = decision == .allowOnce || decision == .allowSession || decision == .alwaysAllow
        return LocalAgentClientGateDecision(generation: rulesGeneration, allowed: allowed, rule: policyStore.rule(for: ruleKey))
    }

    private func applyClientDecision(
        _ decision: LocalAgentApprovalRequest.Decision,
        peer: LocalAgentPeerIdentity,
        ruleKey: LocalAgentClientKey,
        existingRule: LocalAgentClientRule?
    ) {
        switch decision {
        case .allowSession:
            sessionApprovedClients.insert(ruleKey)
            if existingRule == nil {
                policyStore.upsertRule(baseRule(peer: peer, ruleKey: ruleKey, policy: .askSession))
            }
        case .alwaysAllow:
            policyStore.upsertRule(baseRule(peer: peer, ruleKey: ruleKey, policy: .allow, existing: existingRule))
        case .deny, .allowOnce, .timeout:
            break
        }
    }

    private func baseRule(
        peer: LocalAgentPeerIdentity,
        ruleKey: LocalAgentClientKey,
        policy: LocalAgentClientRule.Policy,
        existing: LocalAgentClientRule? = nil
    ) -> LocalAgentClientRule {
        var rule = existing ?? LocalAgentClientRule(
            key: ruleKey,
            displayName: peer.displayName,
            lastPath: peer.path,
            policy: policy
        )
        rule.displayName = peer.displayName
        rule.lastPath = peer.path
        rule.policy = policy
        rule.lastUsedAt = Date()
        return rule
    }

    private func listIdentities(
        rule: LocalAgentClientRule?,
        peer: LocalAgentPeerIdentity,
        destination: LocalAgentBoundDestination?
    ) async -> Data {
        guard lockDigest == nil else {
            return SSHAgentWireCodec.identitiesAnswer([])
        }
        purgeExpiredEphemeralIdentities()

        let allowedIDs = effectiveAllowedKeyIDs(rule: rule)
        var identities: [SSHAgentWireCodec.Identity] = []
        for key in keyManager.savedKeys where allowedIDs == nil || allowedIDs?.contains(key.id) == true {
            var includeCertificate = true
            if key.isOpenPubkey {
                do {
                    if destination != nil {
                        try await OpenPubkeyManager.shared.ensureFreshCertificate(forKeyID: key.id)
                    } else {
                        includeCertificate = try await OpenPubkeyManager.shared.certificateAvailableForPassiveAgentListing(forKeyID: key.id)
                    }
                } catch {
                    includeCertificate = false
                    audit(peer: peer, action: .list, keyName: key.name, outcome: .failed, detail: error.localizedDescription)
                }
            }

            let currentKey = keyManager.savedKeys.first { $0.id == key.id } ?? key
            if let blob = currentKey.publicKeyBlob {
                identities.append(.init(publicKeyBlob: blob, comment: currentKey.name))
            } else if currentKey.authRequirement == .none {
                do {
                    let keyVariant = try await keyManager.loadPrivateKey(id: currentKey.id)
                    var publicKeyBlob = signer.generatePublicKeyBlob(from: keyVariant, keyType: currentKey.keyType)
                    if let blob = publicKeyBlob.readData(length: publicKeyBlob.readableBytes) {
                        identities.append(.init(publicKeyBlob: blob, comment: currentKey.name))
                    }
                } catch {
                    Self.logger.warning("Failed to load key \(currentKey.name) for local agent identity listing: \(error.localizedDescription)")
                }
            }
            if includeCertificate, let cert = currentKey.userCertificate {
                identities.append(.init(publicKeyBlob: cert.certificateBlob, comment: "\(currentKey.name) cert"))
            }
        }
        identities.append(contentsOf: ephemeralIdentities.map {
            SSHAgentWireCodec.Identity(publicKeyBlob: $0.publicKeyBlob, comment: $0.comment)
        })
        return SSHAgentWireCodec.identitiesAnswer(identities)
    }

    private func sign(
        keyBlob: Data,
        data: Data,
        flags: UInt32,
        peer: LocalAgentPeerIdentity,
        destination: LocalAgentBoundDestination?,
        rule: LocalAgentClientRule?
    ) async -> Data {
        guard lockDigest == nil else {
            audit(peer: peer, action: .sign, destination: destination, outcome: .denied, detail: "agent locked")
            return SSHAgentWireCodec.failureFrame
        }
        purgeExpiredEphemeralIdentities()

        if let ephemeral = ephemeralIdentities.first(where: { $0.publicKeyBlob == keyBlob }) {
            return await signEphemeral(ephemeral, data: data, flags: flags, peer: peer, destination: destination)
        }

        guard var keyMeta = signer.findKeyMetadata(publicKeyBlob: ByteBuffer(data: keyBlob)) else {
            audit(peer: peer, action: .sign, destination: destination, outcome: .denied, detail: "unknown key")
            return SSHAgentWireCodec.failureFrame
        }

        if keyMeta.isOpenPubkey {
            do {
                try await OpenPubkeyManager.shared.ensureFreshCertificate(forKeyID: keyMeta.id)
            } catch {
                audit(peer: peer, action: .sign, keyName: keyMeta.name, destination: destination, outcome: .failed, detail: error.localizedDescription)
                return SSHAgentWireCodec.failureFrame
            }

            keyMeta = keyManager.savedKeys.first { $0.id == keyMeta.id } ?? keyMeta
        }

        guard keyIsExposed(keyMeta.id, rule: rule) else {
            audit(peer: peer, action: .sign, keyName: keyMeta.name, destination: destination, outcome: .denied, detail: "key not exposed")
            return SSHAgentWireCodec.failureFrame
        }

        guard destinationAllowed(rule: rule, destination: destination) else {
            audit(peer: peer, action: .sign, keyName: keyMeta.name, destination: destination, outcome: .denied, detail: "destination rejected")
            return SSHAgentWireCodec.failureFrame
        }

        guard await signatureApproved(key: keyMeta, peer: peer, destination: destination, forcePrompt: false) else {
            audit(peer: peer, action: .sign, keyName: keyMeta.name, destination: destination, outcome: .promptedDenied)
            return SSHAgentWireCodec.failureFrame
        }

        do {
            let keyVariant: SSHPrivateKeyVariant
            if keyMeta.yubiKeyInfo != nil {
                keyVariant = try await keyManager.loadPrivateKey(id: keyMeta.id)
            } else if keyMeta.authRequirement == .none {
                keyVariant = try await keyManager.loadPrivateKey(id: keyMeta.id)
            } else {
                keyVariant = try await keyManager.loadPrivateKeyWithAuth(id: keyMeta.id)
            }
            let signature = try await signer.signAsync(
                keyVariant: keyVariant,
                keyType: keyMeta.keyType,
                data: ByteBuffer(data: data),
                flags: flags
            )
            audit(peer: peer, action: .sign, keyName: keyMeta.name, destination: destination, outcome: .allowed)
            return SSHAgentWireCodec.signResponse(Data(buffer: signature))
        } catch {
            audit(peer: peer, action: .sign, keyName: keyMeta.name, destination: destination, outcome: .failed, detail: error.localizedDescription)
            return SSHAgentWireCodec.failureFrame
        }
    }

    private func signEphemeral(
        _ identity: LocalAgentEphemeralIdentity,
        data: Data,
        flags: UInt32,
        peer: LocalAgentPeerIdentity,
        destination: LocalAgentBoundDestination?
    ) async -> Data {
        guard await signatureApproved(
            keyName: identity.comment,
            fingerprint: Self.fingerprint(for: identity.publicKeyBlob),
            keyID: identity.id,
            peer: peer,
            destination: destination,
            forcePrompt: identity.confirmRequired
        ) else {
            audit(peer: peer, action: .sign, keyName: identity.comment, destination: destination, outcome: .promptedDenied)
            return SSHAgentWireCodec.failureFrame
        }
        do {
            let signature = try await signer.signAsync(
                keyVariant: identity.keyVariant,
                keyType: identity.keyType,
                data: ByteBuffer(data: data),
                flags: flags
            )
            audit(peer: peer, action: .sign, keyName: identity.comment, destination: destination, outcome: .allowed)
            return SSHAgentWireCodec.signResponse(Data(buffer: signature))
        } catch {
            audit(peer: peer, action: .sign, keyName: identity.comment, destination: destination, outcome: .failed, detail: error.localizedDescription)
            return SSHAgentWireCodec.failureFrame
        }
    }

    private func signatureApproved(key: SSHKey, peer: LocalAgentPeerIdentity, destination: LocalAgentBoundDestination?, forcePrompt: Bool) async -> Bool {
        await signatureApproved(
            keyName: key.name,
            fingerprint: key.formattedFingerprint,
            keyID: key.id,
            peer: peer,
            destination: destination,
            forcePrompt: forcePrompt
        )
    }

    private func signatureApproved(
        keyName: String,
        fingerprint: String,
        keyID: UUID,
        peer: LocalAgentPeerIdentity,
        destination: LocalAgentBoundDestination?,
        forcePrompt: Bool
    ) async -> Bool {
        let approvalKey = LocalAgentSignatureApprovalKey(keyID: keyID, peer: peer, destination: destination)
        if !forcePrompt {
            switch config.signatureApprovalMode {
            case .autoApprove:
                return true
            case .sessionApprove:
                if sessionApprovedSignatures.contains(approvalKey) { return true }
            case .perRequest:
                break
            }
        }

        let decision = await requestApproval(
            subject: .signature(keyName: keyName, fingerprint: fingerprint),
            peer: peer,
            destination: destination,
            canPersist: false
        )
        let approved = decision == .allowOnce || decision == .allowSession || decision == .alwaysAllow
        if approved, config.signatureApprovalMode == .sessionApprove, !forcePrompt {
            sessionApprovedSignatures.insert(approvalKey)
        }
        return approved
    }

    private func addIdentity(
        _ identity: SSHAgentWireCodec.AddedIdentity,
        constraints: [SSHAgentWireCodec.Constraint],
        peer: LocalAgentPeerIdentity
    ) async -> Data {
        guard lockDigest == nil else { return SSHAgentWireCodec.failureFrame }

        let decision = await requestApproval(
            subject: .addIdentity(comment: identity.comment),
            peer: peer,
            destination: nil,
            canPersist: false
        )
        guard decision == .allowOnce || decision == .allowSession || decision == .alwaysAllow else {
            audit(peer: peer, action: .add, keyName: identity.comment, outcome: .promptedDenied)
            return SSHAgentWireCodec.failureFrame
        }

        let confirm = constraints.contains(.confirm)
        let lifetime = constraints.compactMap { constraint -> UInt32? in
            if case .lifetime(let seconds) = constraint { return seconds }
            return nil
        }.first
        let expiresAt = lifetime.map { Date().addingTimeInterval(TimeInterval($0)) }

        do {
            let ephemeral = try makeEphemeralIdentity(from: identity, confirm: confirm, expiresAt: expiresAt)
            ephemeralIdentities.removeAll { $0.publicKeyBlob == ephemeral.publicKeyBlob }
            ephemeralIdentities.append(ephemeral)
            audit(peer: peer, action: .add, keyName: identity.comment, outcome: .allowed)
            return SSHAgentWireCodec.successFrame
        } catch {
            audit(peer: peer, action: .add, keyName: identity.comment, outcome: .failed, detail: error.localizedDescription)
            return SSHAgentWireCodec.failureFrame
        }
    }

    private func makeEphemeralIdentity(
        from identity: SSHAgentWireCodec.AddedIdentity,
        confirm: Bool,
        expiresAt: Date?
    ) throws -> LocalAgentEphemeralIdentity {
        switch identity.material {
        case .ed25519(_, let seed):
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return LocalAgentEphemeralIdentity(
                id: UUID(),
                publicKeyBlob: identity.publicKeyBlob,
                comment: identity.comment,
                keyType: .ed25519,
                keyVariant: .nioSSH(NIOSSHPrivateKey(ed25519Key: key)),
                confirmRequired: confirm,
                expiresAt: expiresAt
            )
        case .ecdsa(let curve, _, let scalar):
            switch curve {
            case "nistp256":
                let key = try P256.Signing.PrivateKey(rawRepresentation: leftPad(scalar, to: 32))
                return .init(id: UUID(), publicKeyBlob: identity.publicKeyBlob, comment: identity.comment, keyType: .ecdsaP256, keyVariant: .nioSSH(NIOSSHPrivateKey(p256Key: key)), confirmRequired: confirm, expiresAt: expiresAt)
            case "nistp384":
                let key = try P384.Signing.PrivateKey(rawRepresentation: leftPad(scalar, to: 48))
                return .init(id: UUID(), publicKeyBlob: identity.publicKeyBlob, comment: identity.comment, keyType: .ecdsaP384, keyVariant: .nioSSH(NIOSSHPrivateKey(p384Key: key)), confirmRequired: confirm, expiresAt: expiresAt)
            case "nistp521":
                let key = try P521.Signing.PrivateKey(rawRepresentation: leftPad(scalar, to: 66))
                return .init(id: UUID(), publicKeyBlob: identity.publicKeyBlob, comment: identity.comment, keyType: .ecdsaP521, keyVariant: .nioSSH(NIOSSHPrivateKey(p521Key: key)), confirmRequired: confirm, expiresAt: expiresAt)
            default:
                throw LocalAgentError.unsupportedIdentity
            }
        case .rsa(let n, let e, let d):
            let key = Insecure.RSA.PrivateKey(
                modulus: n,
                publicExponent: e,
                privateExponent: d
            )
            return .init(
                id: UUID(),
                publicKeyBlob: identity.publicKeyBlob,
                comment: identity.comment,
                keyType: .rsa,
                keyVariant: .rsa(key),
                confirmRequired: confirm,
                expiresAt: expiresAt
            )
        case .mldsa(let keyType, let publicKey, let seeds):
            let keyVariant: SSHPrivateKeyVariant
            let sshKeyType: SSHKey.KeyType
            switch keyType {
            case LegacyMLDSA44Ed25519SSH.algorithmName:
                let key = try LegacyMLDSA44Ed25519SSH.PrivateKey(seedRepresentation: seeds)
                guard key.compositePublicKey.rawRepresentation == publicKey else {
                    throw LocalAgentError.unsupportedIdentity
                }
                keyVariant = .nioSSH(NIOSSHPrivateKey(custom: key))
                sshKeyType = .mldsa44Ed25519
            case MLDSA44Ed25519SSH.algorithmName:
                let key = try MLDSA44Ed25519SSH.PrivateKey(seedRepresentation: seeds)
                guard key.compositePublicKey.rawRepresentation == publicKey else {
                    throw LocalAgentError.unsupportedIdentity
                }
                keyVariant = .nioSSH(NIOSSHPrivateKey(custom: key))
                sshKeyType = .mldsa44Ed25519
            case "ssh-mldsa44":
                let key = try MLDSA44SSH.PrivateKey(seedRepresentation: seeds)
                guard key.mldsaPublicKey.rawRepresentation == publicKey else {
                    throw LocalAgentError.unsupportedIdentity
                }
                keyVariant = .nioSSH(NIOSSHPrivateKey(custom: key))
                sshKeyType = .mldsa44
            case "ssh-mldsa65":
                guard #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) else {
                    throw LocalAgentError.unsupportedIdentity
                }
                let key = try MLDSA65SSH.PrivateKey(seedRepresentation: seeds)
                guard key.mldsaPublicKey.rawRepresentation == publicKey else {
                    throw LocalAgentError.unsupportedIdentity
                }
                keyVariant = .nioSSH(NIOSSHPrivateKey(custom: key))
                sshKeyType = .mldsa65
            case "ssh-mldsa87":
                guard #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) else {
                    throw LocalAgentError.unsupportedIdentity
                }
                let key = try MLDSA87SSH.PrivateKey(seedRepresentation: seeds)
                guard key.mldsaPublicKey.rawRepresentation == publicKey else {
                    throw LocalAgentError.unsupportedIdentity
                }
                keyVariant = .nioSSH(NIOSSHPrivateKey(custom: key))
                sshKeyType = .mldsa87
            default:
                throw LocalAgentError.unsupportedIdentity
            }
            return LocalAgentEphemeralIdentity(
                id: UUID(),
                publicKeyBlob: identity.publicKeyBlob,
                comment: identity.comment,
                keyType: sshKeyType,
                keyVariant: keyVariant,
                confirmRequired: confirm,
                expiresAt: expiresAt
            )
        case .unsupported:
            throw LocalAgentError.unsupportedIdentity
        }
    }

    private func removeIdentity(keyBlob: Data) -> Bool {
        let before = ephemeralIdentities.count
        ephemeralIdentities.removeAll { $0.publicKeyBlob == keyBlob }
        return ephemeralIdentities.count != before
    }

    private func requestApproval(
        subject: LocalAgentApprovalRequest.Subject,
        peer: LocalAgentPeerIdentity,
        destination: LocalAgentBoundDestination?,
        canPersist: Bool
    ) async -> LocalAgentApprovalRequest.Decision {
        await withCheckedContinuation { continuation in
            let id = UUID()
            pendingContinuations[id] = continuation
            let request = LocalAgentApprovalRequest(
                id: id,
                subject: subject,
                clientName: peer.displayName,
                clientPath: peer.path,
                identityLine: peer.identityLine,
                destination: destination?.displayName,
                canPersist: canPersist
            ) { decision in
                Task { @MainActor in
                    LocalSSHAgentManager.shared.finishApproval(id: id, decision: decision)
                }
            }
            MainAlertController.routeLocalAgentApproval(request)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                LocalSSHAgentManager.shared.finishApproval(id: id, decision: .timeout)
            }
        }
    }

    private func finishApproval(id: UUID, decision: LocalAgentApprovalRequest.Decision) {
        guard let continuation = pendingContinuations.removeValue(forKey: id) else { return }
        MainAlertController.removeLocalAgentApproval(id: id)
        continuation.resume(returning: decision)
    }

    private func effectiveAllowedKeyIDs(rule: LocalAgentClientRule?) -> Set<UUID>? {
        var selected: Set<UUID>?
        if !config.exposedKeyIDs.isEmpty {
            selected = config.exposedKeyIDs
        }
        if let ruleIDs = rule?.allowedKeyIDs {
            selected = selected.map { $0.intersection(ruleIDs) } ?? ruleIDs
        }
        return selected
    }

    private func keyIsExposed(_ id: UUID, rule: LocalAgentClientRule?) -> Bool {
        effectiveAllowedKeyIDs(rule: rule).map { $0.contains(id) } ?? true
    }

    private func destinationAllowed(rule: LocalAgentClientRule?, destination: LocalAgentBoundDestination?) -> Bool {
        guard let rule else { return true }
        if rule.requireSessionBind, destination == nil {
            return false
        }
        guard !rule.pinnedHostKeyFingerprints.isEmpty else { return true }
        guard let destination else { return false }
        return rule.pinnedHostKeyFingerprints.contains(destination.fingerprint)
    }

    private func purgeExpiredEphemeralIdentities() {
        let now = Date()
        ephemeralIdentities.removeAll { identity in
            identity.expiresAt.map { $0 <= now } ?? false
        }
    }

    private func audit(
        peer: LocalAgentPeerIdentity,
        action: LocalAgentAuditEvent.Action,
        keyName: String? = nil,
        destination: LocalAgentBoundDestination? = nil,
        outcome: LocalAgentAuditEvent.Outcome,
        detail: String? = nil
    ) {
        auditLog.append(LocalAgentAuditEvent(
            clientName: peer.displayName,
            clientIdentity: peer.identityLine,
            action: action,
            keyName: keyName,
            destination: destination?.displayName,
            destinationFingerprint: destination?.fingerprint,
            outcome: outcome,
            detail: detail
        ))
    }

    private func action(for request: SSHAgentWireCodec.Request) -> LocalAgentAuditEvent.Action {
        switch request {
        case .listIdentities: return .list
        case .sign: return .sign
        case .addIdentity: return .add
        case .removeIdentity, .removeAll: return .remove
        case .lock: return .lock
        case .unlock: return .unlock
        case .sessionBind: return .sessionBind
        case .unsupported: return .deny
        }
    }

    private static func fingerprint(for blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:\(digest.base64EncodedString().replacingOccurrences(of: "=", with: ""))"
    }

    private func leftPad(_ data: Data, to size: Int) -> Data {
        if data.count == size { return data }
        if data.count > size { return Data(data.suffix(size)) }
        return Data(repeating: 0, count: size - data.count) + data
    }
}

private enum LocalAgentError: LocalizedError {
    case unsupportedIdentity

    var errorDescription: String? {
        switch self {
        case .unsupportedIdentity:
            return String(localized: "Unsupported ssh-add identity", comment: "Local SSH agent ssh-add unsupported identity error")
        }
    }
}

#endif
