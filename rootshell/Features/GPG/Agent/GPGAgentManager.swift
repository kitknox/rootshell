//
//  GPGAgentManager.swift
//  rootshell
//
//  Speaks the Assuan protocol on a forwarded GPG-agent socket.
//
//  One manager per SSH connection that has GPG agent forwarding
//  enabled. The transport (Citadel or trzsz-ssh) hands us each accepted
//  Unix-socket channel as an ``AsyncBytePipe``; we run a per-channel
//  Assuan loop that handles the verbs gpg-agent's "extra" socket
//  exposes: list / probe keys, set the hash + key for an operation,
//  perform `PKSIGN` or `PKDECRYPT`, and answer the housekeeping
//  commands (`RESET`, `GETINFO`, `OPTION`, `BYE`) gpg always sends
//  first.
//
//  The signing path mirrors ``SSHAgentManager``'s three-step pattern:
//  1. Match the key by keygrip against the in-memory metadata index
//     (no Keychain access, no biometric prompt).
//  2. Surface an approval request to the user via
//     ``GPGAgentApprovalRequest``.
//  3. Only after approval, load the secret material from the Keychain
//     and perform the actual cryptographic signature.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Combine
import Crypto
import os.log

// MARK: - Manager

@MainActor
final class GPGAgentManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "GPGAgentManager")

    let config: GPGAgentConfig
    let remoteHost: String
    let sessionName: String

    /// (operation, keygrip) pairs approved during this session — only
    /// consulted when the configured approval mode is
    /// ``GPGAgentConfig/ApprovalMode/sessionApprove``. Keyed by both
    /// fields so approving a sign request doesn't silently authorise
    /// a later decrypt request for the same key (relevant for RSA
    /// SCE keys where sign and encrypt share the keygrip).
    @Published private(set) var sessionApprovedOps: Set<SessionApprovalKey> = []

    /// Composite key for ``sessionApprovedOps``.
    struct SessionApprovalKey: Hashable, Sendable {
        let verb: GPGAgentApprovalRequest.Verb
        let keygrip: String
    }

    /// Currently pending approval request (drives the UI sheet).
    @Published var pendingApproval: GPGAgentApprovalRequest?

    /// Combine publisher of approval requests so non-Published listeners
    /// (e.g. the settings view-model) can also react.
    let approvalRequestPublisher = PassthroughSubject<GPGAgentApprovalRequest, Never>()

    /// Synchronous withdrawal handler set by the owning session at
    /// init. Called whenever an approval request is no longer wanted
    /// (per-request task cancellation, full session teardown). Direct
    /// closure instead of a PassthroughSubject because:
    ///   * `withTaskCancellationHandler.onCancel` runs nonisolatedly;
    ///     a nonisolated Combine subject is awkward under Swift 6
    ///     strict concurrency.
    ///   * Session cleanup cancels the approval pump task *before*
    ///     calling `cancelPendingApprovals()`. With a publisher-based
    ///     pump, withdrawals would be sent after the consumer is
    ///     dead and dropped on the floor; the closure path is
    ///     immediate and doesn't depend on any async pump.
    /// The session implementation hops to MainActor inside as needed.
    nonisolated let onWithdrawal: (@Sendable (UUID) -> Void)?

    private let keyManager: GPGKeyManager
    private let sshKeyManager: SSHKeyManager
    private var openChannels: Int = 0

    /// In-flight approval continuations. Iterated by
    /// ``cancelPendingApprovals()`` on session teardown so the awaits
    /// in ``requestApproval`` resume with `false` and the per-channel
    /// serve tasks exit cleanly instead of suspending forever.
    private var pendingResumers: [ApprovalResumer] = []

    init(
        config: GPGAgentConfig,
        remoteHost: String,
        sessionName: String,
        onWithdrawal: (@Sendable (UUID) -> Void)? = nil,
        keyManager: GPGKeyManager? = nil,
        sshKeyManager: SSHKeyManager? = nil
    ) {
        self.config = config
        self.remoteHost = remoteHost
        self.sessionName = sessionName
        self.onWithdrawal = onWithdrawal
        self.keyManager = keyManager ?? .shared
        self.sshKeyManager = sshKeyManager ?? .shared
    }

    // MARK: - Unified signing source

    /// What ``findSigningSource`` returns: either an imported GPG
    /// subkey or an SSH key whose cached keygrip matched. The PKSIGN
    /// path branches on this so the same Assuan loop drives both
    /// flows.
    private enum SigningSource {
        case gpgSubkey(key: GPGKey, subkey: GPGSubkeyInfo)
        case sshKey(SSHKey)

        var displayName: String {
            switch self {
            case .gpgSubkey(let key, _): return key.name
            case .sshKey(let key): return key.name
            }
        }

        var displayFingerprint: String {
            switch self {
            case .gpgSubkey(_, let sub): return sub.fingerprint.gpgHexUpper
            case .sshKey(let key): return key.fingerprint  // SSH SHA-256 hex
            }
        }

        var keyID: UUID {
            switch self {
            case .gpgSubkey(let key, _): return key.id
            case .sshKey(let key): return key.id
            }
        }

        /// Which signature family the underlying material can produce.
        /// Used to gate digest compatibility before approval — see
        /// ``GPGAgentManager/digestIncompatibilityReason(source:hashAlgorithm:hashLength:)``.
        var signingFamily: SigningFamily {
            switch self {
            case .gpgSubkey(_, let sub):
                switch sub.algorithm {
                case .rsa: return .rsa
                case .ecdsaP256: return .ecdsaP256
                case .eddsaEd25519, .ed25519Native: return .ed25519
                case .ecdhCv25519, .x25519Native, .ecdhP256:
                    // ECDH / X25519 subkeys cannot sign. The PKSIGN
                    // path rejects them at source-resolution time, so
                    // this branch is unreachable for the digest-
                    // compatibility gate. Return `.rsa` as a harmless
                    // placeholder — RSA's gate is the most permissive.
                    return .rsa
                }
            case .sshKey(let key):
                // YubiKey PIV slots wrap the actual algorithm inside
                // yubiKeyInfo; keyType reports `.yubiKeyPIV` for all
                // of them.
                if let yk = key.yubiKeyInfo {
                    switch yk.algorithm {
                    case .rsa2048, .rsa4096: return .rsa
                    case .ecdsaP256: return .ecdsaP256
                    case .ecdsaP384: return .ecdsaP384
                    case .ed25519: return .ed25519
                    // No OpenPGP mapping; unreachable like the software ML-DSA case below.
                    case .mldsa44, .mldsa65, .mldsa87: return .rsa
                    }
                }
                switch key.keyType {
                case .ed25519: return .ed25519
                case .ecdsaP256, .secureEnclaveP256: return .ecdsaP256
                case .ecdsaP384: return .ecdsaP384
                case .ecdsaP521: return .ecdsaP521
                case .rsa: return .rsa
                // FIDO2 / unannotated PIV: GPG forwarding doesn't
                // currently sign with these (FIDO2 needs a challenge,
                // and unannotated PIV is unreachable via our normal
                // load path). Returning .rsa is a no-op label — the
                // gate downstream will mark the digest "OK" for RSA,
                // then the actual signer rejects the operation.
                case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey: return .rsa
                // External-agent keys are never advertised to GPG (the
                // ssh-agent protocol can't produce GPG's raw signatures);
                // same no-op label as the FIDO2 cases above.
                case .externalAgent: return .rsa
                // Composite PQ keys have no OpenPGP mapping (keygrip is
                // nil), so this label is unreachable — same no-op.
                case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87: return .rsa
                }
            }
        }
    }

    /// Coarse family used solely for digest-compatibility gating.
    /// Doesn't carry curve parameters etc — those are validated again
    /// at signing time.
    private enum SigningFamily {
        case rsa
        case ed25519
        case ecdsaP256
        case ecdsaP384
        case ecdsaP521
    }

    /// Returns a human-readable rejection reason if `hashAlgorithm` /
    /// `hashLength` are incompatible with what the resolved `source`
    /// can sign. Returns nil when the combination is fine.
    ///
    /// The check exists because:
    ///   * SETHASH happens before SIGKEY in some flows, so we can't
    ///     gate it there;
    ///   * gpg-agent permissively accepts any algorithm at SETHASH;
    ///   * but our backends are stricter — ECDSA P-256 on Apple
    ///     SecKey + YubiKey only accepts a 32-byte SHA-256 digest,
    ///     Ed25519 doesn't take a pre-hash, etc. Without this gate
    ///     the user would Face-ID, then signing would still fail.
    private func digestIncompatibilityReason(
        source: SigningSource,
        hashAlgorithm: GPGHashAlgorithm,
        hashLength: Int
    ) -> String? {
        switch source.signingFamily {
        case .rsa:
            // RSA happily PKCS#1-pads any of the named hashes we support.
            if case .unknown(let id) = hashAlgorithm {
                return "Unsupported hash algorithm \(id) for RSA"
            }
            return nil
        case .ed25519:
            // Ed25519 signs the pre-hashed message as-is. Both
            // GPGSigner and SSHKeyGPGBridge pass the digest straight
            // to CryptoKit's Curve25519.Signing.PrivateKey.signature(
            // for:), which accepts arbitrary-length input. Modern
            // clients default to SHA-512 (64 bytes, algo 10) for
            // Ed25519 OpenPGP keys; older clients may still send
            // SHA-256 (32 bytes). Both are valid, no gating needed.
            return nil
        case .ecdsaP256:
            if hashLength != 32 {
                return "ECDSA P-256 requires a 32-byte digest (SHA-256); got \(hashLength)"
            }
            return nil
        case .ecdsaP384:
            if hashLength != 48 {
                return "ECDSA P-384 requires a 48-byte digest (SHA-384); got \(hashLength)"
            }
            return nil
        case .ecdsaP521:
            // P-521 expects a 66-byte digest after the conventional
            // left-truncation; clients almost always send SHA-512 (64
            // bytes) which Apple's SecKey accepts via the variant
            // entry point. Allow either 64 or 66.
            if hashLength != 64 && hashLength != 66 {
                return "ECDSA P-521 requires a 64- or 66-byte digest; got \(hashLength)"
            }
            return nil
        }
    }

    /// What operation we're about to perform with a resolved key.
    /// Used by both the lookup path (to know which grip matched) and
    /// the handler path (to gate PKSIGN/PKDECRYPT on the source's
    /// capability).
    ///
    /// `.both` covers SSH RSA / ECDSA-P256 keys where the signing and
    /// encryption keygrips are byte-identical (the keygrip hash
    /// covers curve params + public point only, not the algorithm
    /// name). Without this case, those keys would resolve as one role
    /// and the other handler would reject as "not capable" even
    /// though the underlying primitive can serve both verbs.
    private enum KeyRole {
        case sign
        case decrypt
        case both

        var canSign: Bool { self == .sign || self == .both }
        var canDecrypt: Bool { self == .decrypt || self == .both }
    }

    /// Resolve a keygrip to a source + the role that grip plays for
    /// that source. Imported GPG subkeys carry their capability in
    /// ``GPGSubkeyInfo/capability``; SSH keys can match either
    /// ``SSHKey/gpgKeygripHex`` (sign) or ``SSHKey/gpgEncryptionKeygripHex``
    /// (decrypt), with both grips equal for RSA + ECDSA P-256. The
    /// per-connection ``GPGAgentConfig/forwardedKeyIDs`` whitelist
    /// gates both.
    private func findSource(byKeygripHex hex: String) -> (source: SigningSource, role: KeyRole)? {
        let normalised = hex.uppercased()
        if let match = keyManager.findSubkey(byKeygripHex: normalised),
           configurationAllowsKeyID(match.key.id) {
            let cap = match.subkey.capability
            let role: KeyRole
            switch cap {
            case .signAndEncrypt: role = .both
            case .sign: role = .sign
            case .encrypt: role = .decrypt
            case .other:
                // Auth-only or otherwise non-sign/non-encrypt keys
                // aren't usable for PKSIGN or PKDECRYPT. Treat the
                // keygrip as unknown so the verb-specific gates
                // return "key not present" instead of routing the
                // request to a key that can't service it.
                return nil
            }
            return (.gpgSubkey(key: match.key, subkey: match.subkey), role)
        }
        for sshKey in sshKeyManager.savedKeys where configurationAllowsKeyID(sshKey.id) {
            let signMatch = sshKey.gpgKeygripHex?.uppercased() == normalised
            let encryptMatch = sshKey.gpgEncryptionKeygripHex?.uppercased() == normalised
            // RSA + ECDSA-P256 collide both grips into one value, so
            // the sign-side match and the encrypt-side match fire
            // together — that's a `.both` role. Ed25519 keys answer
            // each verb on a distinct grip.
            switch (signMatch, encryptMatch) {
            case (true, true): return (.sshKey(sshKey), .both)
            case (true, false): return (.sshKey(sshKey), .sign)
            case (false, true): return (.sshKey(sshKey), .decrypt)
            case (false, false): continue
            }
        }
        return nil
    }

    /// Compatibility wrapper for the existing call sites that just
    /// need a source. Drops the role hint.
    private func findSigningSource(byKeygripHex hex: String) -> SigningSource? {
        findSource(byKeygripHex: hex)?.source
    }

    /// Called by the user from the approval sheet.
    func respondToApproval(_ approved: Bool) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        pending.completion(approved)
    }

    // MARK: - Channel entry point

    /// Serve one forwarded Unix-socket connection. Returns when the
    /// remote sends `BYE` or the channel closes.
    func serve(stream: AsyncBytePipe) async {
        guard config.enabled else {
            // Forwarding-disabled state: the remote shouldn't be
            // reaching us at all if the SSH layer wired the config
            // correctly, but defend in depth.
            await stream.close()
            return
        }

        openChannels += 1
        defer {
            openChannels -= 1
            Task { await stream.close() }
        }

        var session = AssuanSession()
        await session.greet(stream: stream)

        do {
            try await runLoop(stream: stream, session: &session)
        } catch {
            Self.logger.warning("Assuan loop ended with error: \(error.localizedDescription)")
        }
    }

    // MARK: - Read/write loop

    private func runLoop(stream: AsyncBytePipe, session: inout AssuanSession) async throws {
        let reader = AssuanReader(stream: stream)
        var keepGoing = true
        while keepGoing {
            guard let line = try await reader.readLine() else { return }
            keepGoing = try await handle(line: line, stream: stream, reader: reader, session: &session)
        }
    }

    // MARK: - Verb dispatch

    private func handle(line: AssuanLine, stream: AsyncBytePipe, reader: AssuanReader, session: inout AssuanSession) async throws -> Bool {
        Self.logger.debug("→ \(line.verb) \(line.argument.prefix(64))")

        switch line.verb.uppercased() {
        case "BYE":
            try await write(stream, "OK closing connection")
            return false

        case "RESET":
            session.reset()
            try await ok(stream)

        case "OPTION":
            // We don't honour any of gpg-agent's options (ttyname,
            // display, locale, allow-pinentry-notify, etc.) but the
            // remote always sends a handful of them and expects "OK".
            try await ok(stream)

        case "SETKEYDESC":
            // gpg sends this before PKSIGN to set the pinentry prompt
            // text ("Please enter the passphrase to unlock..."). We
            // never run pinentry — auth happens via Face ID / NFC on
            // the iPad — so the description is irrelevant. Accept
            // silently; rejecting here aborts the signing flow with
            // gpg's "clear-sign failed: Not implemented" error.
            try await ok(stream)

        case "GETINFO":
            try await handleGetInfo(line.argument, stream: stream)

        case "AGENT_ID":
            // Deprecated alias for GETINFO socket_name in some clients.
            try await ok(stream)

        case "KEYINFO":
            try await handleKeyInfo(keygripHex: line.argument, stream: stream)

        case "HAVEKEY":
            try await handleHaveKey(keygripList: line.argument, stream: stream)

        case "SIGKEY", "SETKEY":
            try await handleSetSignKey(keygripHex: line.argument, stream: stream, session: &session)

        case "SETHASH":
            try await handleSetHash(argument: line.argument, stream: stream, session: &session)

        case "PKSIGN":
            try await handlePKSIGN(stream: stream, session: &session)

        case "PKDECRYPT":
            try await handlePKDECRYPT(argument: line.argument, stream: stream, reader: reader, session: &session)

        case "SCD":
            // SmartCard daemon passthrough — we don't speak it.
            try await err(stream, code: AssuanError.notImplemented, message: "SCD not supported")

        case "":
            // Blank line. gpg-agent ignores these; do the same.
            break

        default:
            try await err(stream, code: AssuanError.notImplemented, message: "Unknown command '\(line.verb)'")
        }
        return true
    }

    // MARK: - GETINFO

    private func handleGetInfo(_ what: String, stream: AsyncBytePipe) async throws {
        switch what.lowercased() {
        case "version":
            try await write(stream, "D 2.4.8")  // Avoid older-agent compatibility fallbacks.
            try await ok(stream)
        case "pid":
            try await write(stream, "D \(ProcessInfo.processInfo.processIdentifier)")
            try await ok(stream)
        case "socket_name":
            try await write(stream, "D rootshell:forwarded")
            try await ok(stream)
        default:
            try await err(stream, code: AssuanError.notImplemented, message: "GETINFO '\(what)' not supported")
        }
    }

    // MARK: - KEYINFO

    /// gpg-agent's `KEYINFO <keygrip>` response shape:
    ///
    ///     S KEYINFO <grip> <type> <serialno> <idstr> <cached> <protection> <fpr>
    ///     OK
    ///
    /// We answer with the standard placeholder field shape for keys
    /// we have, and ERR for keygrips we don't recognise.
    private func handleKeyInfo(keygripHex: String, stream: AsyncBytePipe) async throws {
        let trimmed = keygripHex.trimmingCharacters(in: .whitespaces)

        // `KEYINFO --list` enumerates every keygrip the agent claims.
        // Newer clients also use `--data` as a fast path: one D-line
        // containing newline-separated rows without the `KEYINFO`
        // status prefix.
        let tokens = trimmed
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        let isListForm = tokens.contains(where: { $0.hasPrefix("--list") })
        let wantsData = tokens.contains(where: { $0 == "--data" })
        if isListForm {
            try await emitAllKeygripLines(stream: stream, asData: wantsData)
            try await ok(stream)
            return
        }

        let normalised = trimmed.uppercased()
        guard findSigningSource(byKeygripHex: normalised) != nil else {
            try await err(stream, code: AssuanError.noSecKey, message: "Key not present")
            return
        }
        let response = "S KEYINFO \(keyInfoStatusRow(for: normalised))"
        try await write(stream, response)
        try await ok(stream)
    }

    /// Walk every signing source (SSH keys with a cached keygrip +
    /// imported GPG keys) and emit one `S KEYINFO` line per keygrip
    /// — the canonical reply shape for `KEYINFO --list`. Respects
    /// ``GPGAgentConfig/forwardedKeyIDs`` so a user who limited the
    /// connection to a specific subset doesn't see other keys leak
    /// onto the enumeration.
    private func emitAllKeygripLines(stream: AsyncBytePipe, asData: Bool) async throws {
        var rows: [String] = []

        // GPG side. Skip subkeys with `.other` capability — those
        // advertise neither sign nor encrypt (auth-only, group key,
        // etc.) and would mislead the remote into selecting a key
        // the agent can't service.
        for gpgKey in keyManager.savedKeys where configurationAllowsKeyID(gpgKey.id) {
            for (gripHex, sub) in gpgKey.keygripIndex where sub.capability != .other {
                rows.append(keyInfoStatusRow(for: gripHex))
            }
        }
        // SSH side. Emit both signing and encryption keygrips so the
        // remote can `gpg --list-keys --with-keygrip` and see the same
        // pair of grips it would for a software OpenPGP key that has
        // sign+encrypt subkeys. For RSA + ECDSA P-256 the two grips
        // are identical — we dedupe before emitting so we don't write
        // the same line twice. Ed25519 keys advertise two distinct
        // grips (Ed25519 sign + cv25519 encrypt).
        for sshKey in sshKeyManager.savedKeys where configurationAllowsKeyID(sshKey.id) {
            var emitted: Set<String> = []
            if let signGrip = sshKey.gpgKeygripHex?.uppercased() {
                emitted.insert(signGrip)
                rows.append(keyInfoStatusRow(for: signGrip))
            }
            if let encGrip = sshKey.gpgEncryptionKeygripHex?.uppercased(),
               !emitted.contains(encGrip) {
                rows.append(keyInfoStatusRow(for: encGrip))
            }
        }

        if asData {
            guard !rows.isEmpty else { return }
            let payload = Data((rows.joined(separator: "\n") + "\n").utf8)
            try await writeDataLines(stream, payload: payload)
        } else {
            for row in rows {
                try await write(stream, "S KEYINFO \(row)")
            }
        }
    }

    /// Standard agent implementations currently emit:
    /// `<grip> D - - - C - - -`
    /// for both single-key and list forms. The exact cache/protection
    /// markers are advisory; keeping the field count and
    /// placeholders aligned is what matters for fast key listing.
    private func keyInfoStatusRow(for keygripHex: String) -> String {
        "\(keygripHex.uppercased()) D - - - C - - -"
    }

    // MARK: - HAVEKEY

    /// `HAVEKEY <grip1> <grip2> …` — returns OK if any grip is available,
    /// otherwise `ERR No_Secret_Key`. `HAVEKEY --list[=<limit>]`
    /// returns raw 20-byte keygrips on D-lines.
    private func handleHaveKey(keygripList: String, stream: AsyncBytePipe) async throws {
        let trimmed = keygripList.trimmingCharacters(in: .whitespaces)
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let listToken = tokens.first(where: { $0 == "--list" || $0.hasPrefix("--list=") }) {
            let limit: Int?
            if let equal = listToken.firstIndex(of: "=") {
                limit = Int(listToken[listToken.index(after: equal)...])
            } else {
                limit = nil
            }
            try await emitHaveKeyList(stream: stream, limit: limit)
            try await ok(stream)
            return
        }

        if tokens.first == "--info", tokens.count >= 2 {
            let grip = tokens[1].uppercased()
            if findSigningSource(byKeygripHex: grip) != nil {
                try await write(stream, "S KEYFILEINFO clear")
                try await ok(stream)
            } else {
                try await err(stream, code: AssuanError.noSecKey, message: "No matching key")
            }
            return
        }

        let grips = keygripList
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { String($0).uppercased() }
        for grip in grips {
            if findSigningSource(byKeygripHex: grip) != nil {
                try await ok(stream)
                return
            }
        }
        try await err(stream, code: AssuanError.noSecKey, message: "No matching key")
    }

    private func emitHaveKeyList(stream: AsyncBytePipe, limit: Int?) async throws {
        var payload = Data()
        var seen: Set<String> = []
        var count = 0

        for gripHex in availableKeygripHexes() {
            guard seen.insert(gripHex).inserted,
                  let grip = GPGHex.decode(gripHex),
                  grip.count == 20 else {
                continue
            }
            if let limit, count >= limit { break }
            payload.append(grip)
            count += 1
        }

        if !payload.isEmpty {
            try await writeDataLines(stream, payload: payload)
        }
    }

    private func availableKeygripHexes() -> [String] {
        var grips: [String] = []

        for gpgKey in keyManager.savedKeys where configurationAllowsKeyID(gpgKey.id) {
            for (gripHex, sub) in gpgKey.keygripIndex where sub.capability != .other {
                grips.append(gripHex.uppercased())
            }
        }

        for sshKey in sshKeyManager.savedKeys where configurationAllowsKeyID(sshKey.id) {
            if let signGrip = sshKey.gpgKeygripHex?.uppercased() {
                grips.append(signGrip)
            }
            if let encGrip = sshKey.gpgEncryptionKeygripHex?.uppercased() {
                grips.append(encGrip)
            }
        }

        return grips
    }

    // MARK: - SIGKEY / SETKEY

    private func handleSetSignKey(keygripHex: String, stream: AsyncBytePipe, session: inout AssuanSession) async throws {
        let trimmed = keygripHex.trimmingCharacters(in: .whitespaces).uppercased()
        guard let source = findSigningSource(byKeygripHex: trimmed) else {
            try await err(stream, code: AssuanError.noSecKey, message: "Key not present")
            return
        }
        session.activeKeygrip = trimmed
        session.activeSourceTag = sourceTag(for: source)
        try await ok(stream)
    }

    /// Stable identifier used to re-locate the active signing source
    /// inside the PKSIGN handler. We carry the keygrip and an enum
    /// tag rather than a captured ``SigningSource`` because Swift's
    /// inout-passed session is a value type and storing the enum
    /// directly would force us to re-add a Sendable trait we'd rather
    /// not worry about for what's a single-line re-resolution.
    enum SourceTag: Hashable, Sendable {
        case gpg(keyID: UUID)
        case ssh(keyID: UUID)
    }

    private func sourceTag(for source: SigningSource) -> SourceTag {
        switch source {
        case .gpgSubkey(let key, _): return .gpg(keyID: key.id)
        case .sshKey(let key): return .ssh(keyID: key.id)
        }
    }

    private func resolveSource(tag: SourceTag, keygripHex: String) -> SigningSource? {
        switch tag {
        case .gpg:
            return keyManager.findSubkey(byKeygripHex: keygripHex).map { .gpgSubkey(key: $0.key, subkey: $0.subkey) }
        case .ssh(let keyID):
            return sshKeyManager.findKey(id: keyID).map { .sshKey($0) }
        }
    }

    // MARK: - SETHASH

    private func handleSetHash(argument: String, stream: AsyncBytePipe, session: inout AssuanSession) async throws {
        // Format: "<algo-id> <hex-hash>"  or  "--hash=<algo-name> <hex-hash>"
        let parts = argument.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else {
            try await err(stream, code: AssuanError.invalidValue, message: "SETHASH needs algo and hash")
            return
        }
        let algoToken = String(parts[0])
        let hashHex = String(parts[1])

        // Two forms in the wild:
        //   SETHASH 8 <hex>                 — numeric algo id
        //   SETHASH --hash=sha256 <hex>     — long-option form
        // Anything else is rejected. Previously a non-numeric token
        // silently defaulted to SHA-256, so `--hash=sha512 <64-byte>`
        // was rejected as a SHA-256 length mismatch instead of being
        // honoured.
        let algo: GPGHashAlgorithm
        if let id = Int(algoToken) {
            algo = GPGHashAlgorithm(rawValue: id)
        } else if let named = parseHashOption(algoToken) {
            algo = named
        } else {
            try await err(stream, code: AssuanError.invalidValue,
                          message: "SETHASH unrecognised algorithm '\(algoToken)'")
            return
        }
        guard let hash = GPGHex.decode(hashHex), let expectedLen = algo.digestByteCount, hash.count == expectedLen else {
            try await err(stream, code: AssuanError.invalidValue, message: "SETHASH digest length mismatch")
            return
        }
        session.hash = hash
        session.hashAlgorithm = algo
        try await ok(stream)
    }

    // MARK: - PKSIGN

    private func handlePKSIGN(stream: AsyncBytePipe, session: inout AssuanSession) async throws {
        guard let keygripHex = session.activeKeygrip,
              let tag = session.activeSourceTag,
              let source = resolveSource(tag: tag, keygripHex: keygripHex),
              let hash = session.hash,
              let algo = session.hashAlgorithm else {
            try await err(stream, code: AssuanError.invalidValue,
                          message: "PKSIGN without prior SIGKEY/SETHASH")
            return
        }

        // Reject encryption-only keys before prompting. SIGKEY accepts
        // any matching keygrip (gpg uses the same verb for SETKEY in
        // PKDECRYPT), but PKSIGN must refuse keys that can't sign —
        // otherwise the user Face-IDs through an approval prompt that
        // the actual signer would fail to honour. Mirrors handlePKDECRYPT's
        // sourceCanDecrypt gate.
        if !sourceCanSign(source: source, keygripHex: keygripHex) {
            try await err(stream, code: AssuanError.invalidValue,
                          message: "Key not capable of signing")
            session.hash = nil
            session.hashAlgorithm = nil
            return
        }

        // Reject digest/key-algorithm mismatches BEFORE prompting for
        // approval. Without this gate the user could approve + face-
        // ID, then signing would still fail because the backend can't
        // handle the digest (e.g. ECDSA P-256 is curve-locked to a
        // 32-byte SHA-256 digest on Apple's SecKey / our YubiKey
        // signer, so SHA-384/512 just doesn't work).
        if let reason = digestIncompatibilityReason(source: source, hashAlgorithm: algo, hashLength: hash.count) {
            try await err(stream, code: AssuanError.invalidValue, message: reason)
            session.hash = nil
            session.hashAlgorithm = nil
            return
        }

        // Step 1: approval (no Keychain access yet).
        let approved = await requestApproval(for: source, keygripHex: keygripHex, hash: hash, algorithm: algo)
        guard approved else {
            try await err(stream, code: AssuanError.canceled, message: "User declined signing request")
            return
        }
        if config.approvalMode == .sessionApprove {
            sessionApprovedOps.insert(SessionApprovalKey(verb: .sign, keygrip: keygripHex))
        }

        // Step 2: load secret material (biometric prompt if required)
        // and produce the signature. The two branches share the same
        // approval / Assuan-reply contract but differ in where the
        // private material comes from.
        let sigPayload: Data
        do {
            switch source {
            case .gpgSubkey(let key, _):
                let reason = String(localized: "Sign with '\(key.name)'",
                                    comment: "GPG agent biometric prompt reason")
                let loaded = try await keyManager.loadKeyWithAuth(id: key.id, reason: reason)
                guard let subkey = loaded.subkey(forKeygrip: keygripHex) else {
                    try await err(stream, code: AssuanError.noSecKey, message: "Loaded key missing the requested subkey")
                    return
                }
                // Hop the RSA/EdDSA/ECDSA math off the MainActor — for
                // RSA-4096 PKSIGN this is tens of ms of modexp that
                // would otherwise freeze the UI on every git commit
                // signature.
                sigPayload = try await Task.detached(priority: .userInitiated) {
                    try GPGSigner.sign(subkey: subkey, hash: hash, hashAlgorithm: algo)
                }.value

            case .sshKey(let sshKey):
                let variant: SSHPrivateKeyVariant
                if sshKey.authRequirement == .none {
                    variant = try await sshKeyManager.loadPrivateKey(id: sshKey.id)
                } else {
                    variant = try await sshKeyManager.loadPrivateKeyWithAuth(id: sshKey.id)
                }
                sigPayload = try await SSHKeyGPGBridge.sign(
                    variant: variant,
                    keyType: sshKey.keyType,
                    hash: hash,
                    hashAlgorithm: algo
                )
            }
        } catch SSHKeyManager.LoadError.authenticationCancelled,
                GPGKeyManager.LoadError.authenticationCancelled {
            try await err(stream, code: AssuanError.canceled, message: "Authentication cancelled")
            return
        } catch SSHKeyManager.LoadError.authenticationFailed,
                GPGKeyManager.LoadError.authenticationFailed {
            try await err(stream, code: AssuanError.canceled, message: "Authentication failed")
            return
        } catch {
            try await err(stream, code: AssuanError.generalError, message: "Signature failed: \(error.localizedDescription)")
            return
        }

        try await writeDataLine(stream, payload: sigPayload)
        try await ok(stream)
        // Per gpg-agent's conventions the active key persists across
        // sign calls within the same connection; only the hash is
        // single-shot.
        session.hash = nil
        session.hashAlgorithm = nil
    }

    // MARK: - PKDECRYPT

    private func handlePKDECRYPT(argument: String, stream: AsyncBytePipe, reader: AssuanReader, session: inout AssuanSession) async throws {
        guard let keygripHex = session.activeKeygrip else {
            try await err(stream, code: AssuanError.invalidValue,
                          message: "PKDECRYPT without prior SETKEY")
            return
        }
        guard let replyMode = pkDecryptReplyMode(argument: argument) else {
            try await err(stream, code: AssuanError.notImplemented, message: "Unsupported PKDECRYPT KEM mode")
            return
        }
        guard let resolved = findSource(byKeygripHex: keygripHex) else {
            try await err(stream, code: AssuanError.noSecKey, message: "Key not present")
            return
        }
        let source = resolved.source
        // Reject sign-only keys before going through INQUIRE + approval
        // (mirrors gpg-agent's behaviour: it would route this to the
        // ECDH/RSA decrypt path and immediately fail). For GPG subkeys
        // we check the parsed capability; for SSH keys we check which
        // grip matched.
        if !sourceCanDecrypt(source: source, role: resolved.role) {
            try await err(stream, code: AssuanError.invalidValue,
                          message: "Key not capable of decryption")
            return
        }

        // INQUIRE for the ciphertext. Gpg responds with one or more
        // `D <%-escaped bytes>` lines and a terminating `END`.
        try await write(stream, "S INQUIRE_MAXLEN \(Self.maxInquireLength)")
        try await write(stream, "INQUIRE CIPHERTEXT")

        var ciphertext = Data()
        readLoop: while true {
            guard let line = try await reader.readLine() else {
                try await err(stream, code: AssuanError.generalError,
                              message: "Connection closed during INQUIRE")
                return
            }
            let verb = line.verb.uppercased()
            switch verb {
            case "END":
                break readLoop
            case "CAN":
                try await err(stream, code: AssuanError.canceled,
                              message: "Client cancelled inquiry")
                return
            case "D":
                // Operate on raw bytes — D-line payloads contain
                // arbitrary octets after %-unescaping and would be
                // lossy through a UTF-8 String round-trip.
                if ciphertext.count + line.argumentBytes.count > Self.maxInquireLength {
                    try await err(stream, code: AssuanError.invalidValue,
                                  message: "Ciphertext exceeds INQUIRE_MAXLEN")
                    return
                }
                ciphertext.append(unescapeAssuanDataLine(line.argumentBytes))
            default:
                // Some clients send extra status lines mid-inquire;
                // be permissive and ignore.
                continue
            }
        }
        // Parse the S-expression. Malformed input is the client's
        // fault — return invalidValue with a short generic message.
        let encVal: SExpr
        do {
            encVal = try SExpressionParser.parse(ciphertext, maxAtomLength: Self.maxInquireLength)
        } catch {
            Self.logger.warning("PKDECRYPT ciphertext parse failed: \(error.localizedDescription)")
            try await err(stream, code: AssuanError.invalidValue,
                          message: "Malformed ciphertext S-expression")
            return
        }

        // Approval flow with verb=.decrypt — same gating modes as
        // sign (auto / session / per-request), different UI copy.
        let approved = await requestDecryptApproval(for: source, keygripHex: keygripHex)
        guard approved else {
            try await err(stream, code: AssuanError.canceled,
                          message: "User declined decryption request")
            return
        }
        if config.approvalMode == .sessionApprove {
            sessionApprovedOps.insert(SessionApprovalKey(verb: .decrypt, keygrip: keygripHex))
        }

        // Load secret + run the decrypt. Plain PKDECRYPT returns the
        // ECDH shared secret for older clients; KEM mode returns the
        // already-unwrapped session frame.
        let replyPayload: Data
        do {
            switch source {
            case .gpgSubkey(let key, _):
                let reason = String(localized: "Decrypt with '\(key.name)'",
                                    comment: "GPG agent biometric prompt reason")
                let loaded = try await keyManager.loadKeyWithAuth(id: key.id, reason: reason)
                guard let subkey = loaded.subkey(forKeygrip: keygripHex) else {
                    try await err(stream, code: AssuanError.noSecKey, message: "Loaded key missing the requested subkey")
                    return
                }
                // RFC 6637 §8: the KDF "Param" includes the
                // recipient fingerprint — for a message encrypted
                // to an ECDH subkey, that's the SUBKEY's
                // fingerprint, not the certifying primary's.
                //
                // Run the modexp / ECDH / KDF / AES-unwrap off the
                // MainActor — RSA-4096 PKDECRYPT can be ≥100 ms and
                // would otherwise freeze the UI for the duration of
                // every encrypted message gpg pipes through.
                let subkeyFingerprint = subkey.fingerprint
                replyPayload = try await Task.detached(priority: .userInitiated) {
                    try GPGDecryptor.decrypt(
                        subkey: subkey,
                        encValSExpr: encVal,
                        primaryFingerprint: subkeyFingerprint,
                        replyMode: replyMode
                    )
                }.value
            case .sshKey(let sshKey):
                let variant: SSHPrivateKeyVariant
                if sshKey.authRequirement == .none {
                    variant = try await sshKeyManager.loadPrivateKey(id: sshKey.id)
                } else {
                    variant = try await sshKeyManager.loadPrivateKeyWithAuth(id: sshKey.id)
                }
                // Compute the v4 fingerprint of the ECDH subkey we
                // emit at export time. The remote saw this same
                // fingerprint when it imported our public-key block
                // and used it as the KDF "Param" recipient
                // fingerprint when encrypting, so we must reproduce
                // it exactly here to derive the matching KEK.
                let ctime = UInt32(truncatingIfNeeded: Int(sshKey.createdDate.timeIntervalSince1970))
                let fp = SSHKeyGPGBridge.openPGPEncryptionFingerprint(
                    for: variant, keyType: sshKey.keyType, ctime: ctime
                ) ?? Data(repeating: 0, count: 20)
                replyPayload = try await SSHKeyGPGBridge.decryptRaw(
                    variant: variant,
                    keyType: sshKey.keyType,
                    encValSExpr: encVal,
                    primaryFingerprint: fp,
                    replyMode: replyMode
                )
            }
        } catch SSHKeyManager.LoadError.authenticationCancelled,
                GPGKeyManager.LoadError.authenticationCancelled {
            try await err(stream, code: AssuanError.canceled, message: "Authentication cancelled")
            return
        } catch SSHKeyManager.LoadError.authenticationFailed,
                GPGKeyManager.LoadError.authenticationFailed {
            try await err(stream, code: AssuanError.canceled, message: "Authentication failed")
            return
        } catch let err as GPGDecryptError {
            Self.logger.warning("PKDECRYPT failed: \(err.localizedDescription)")
            try await self.err(stream, code: AssuanError.invalidValue,
                               message: "Decryption failed: \(err.localizedDescription)")
            return
        } catch {
            Self.logger.warning("PKDECRYPT failed: \(error.localizedDescription)")
            try await self.err(stream, code: AssuanError.generalError,
                               message: "Decryption failed: \(error.localizedDescription)")
            return
        }
        // Match gpg-agent's exact reply shape: a `S PADDING 0` status
        // line precedes the data line for RSA-PKCS#1-v1.5. gpg's
        // client tracks this in `parm->padding` and uses it to decide
        // whether the result needs further unpadding. 0 = "already
        // unpadded by the agent", which is what BoringSSL's
        // RSA_PKCS1_PADDING gives us; without this line gpg rejects
        // the result with "Wrong secret key used" even when the
        // bytes are correct.
        if sourceIsRSA(source) {
            try await write(stream, "S PADDING 0")
        }
        try await writeDataLine(stream, payload: CanonicalSExpression.valueReply(replyPayload))
        try await ok(stream)
    }

    private func pkDecryptReplyMode(argument: String) -> GPGDecryptor.ReplyMode? {
        let tokens = argument
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let kemToken = tokens.first(where: { $0 == "--kem" || $0.hasPrefix("--kem=") }) else {
            return .legacyECDHSharedSecret
        }
        if kemToken == "--kem=pgp" {
            return .unwrappedSessionKey
        }
        return nil
    }

    /// Whether the resolved source is RSA — gates the `S PADDING 0`
    /// status line on PKDECRYPT replies. ECDH replies do not carry a
    /// padding state, whether the payload is a shared secret or an
    /// unwrapped session frame. YubiKey PIV RSA slots also count:
    /// their `keyType` is ``.yubiKeyPIV`` with the real
    /// algorithm tagged on ``SSHKey/yubiKeyInfo`` — without inspecting
    /// that, RSA decrypts via the card return the already-unpadded
    /// plaintext but gpg still mis-checksums for lack of the
    /// padding-state announcement.
    private func sourceIsRSA(_ source: SigningSource) -> Bool {
        switch source {
        case .gpgSubkey(_, let sub):
            return sub.algorithm == .rsa
        case .sshKey(let key):
            if key.keyType == .rsa { return true }
            if let yk = key.yubiKeyInfo {
                return yk.algorithm == .rsa2048 || yk.algorithm == .rsa4096
            }
            return false
        }
    }

    /// Whether the resolved source + matched grip role permits
    /// decryption. For GPG subkeys this consults the parsed
    /// capability; for SSH keys the role tag from
    /// ``findSource(byKeygripHex:)`` already encodes which grip
    /// matched.
    private func sourceCanDecrypt(source: SigningSource, role: KeyRole) -> Bool {
        switch source {
        case .gpgSubkey(_, let sub):
            return sub.capability.canEncrypt
        case .sshKey:
            return role.canDecrypt
        }
    }

    /// Whether the resolved source can serve a PKSIGN against the
    /// given active keygrip. Mirror of ``sourceCanDecrypt``.
    ///
    /// GPG subkeys consult the parsed key-flag capability. SSH keys
    /// distinguish by which grip the remote selected: SETKEY with the
    /// signing grip → can sign; SETKEY with the encryption-only grip
    /// (Ed25519 keys expose a separate cv25519 grip) → must refuse.
    /// For RSA / ECDSA-P256 the two grips are byte-identical, so the
    /// signing-grip check answers both.
    private func sourceCanSign(source: SigningSource, keygripHex: String) -> Bool {
        switch source {
        case .gpgSubkey(_, let sub):
            return sub.capability.canSign
        case .sshKey(let key):
            return key.gpgKeygripHex?.uppercased() == keygripHex.uppercased()
        }
    }

    /// Variant of ``requestApproval`` for PKDECRYPT — same gating
    /// modes (auto/session/per-request) and the same race-safe
    /// continuation handling, but the surfaced request uses
    /// `verb = .decrypt` so the UI shows "Decrypt with X" instead of
    /// "Sign with X" and skips the hash-preview row.
    private func requestDecryptApproval(
        for source: SigningSource,
        keygripHex: String
    ) async -> Bool {
        switch config.approvalMode {
        case .autoApprove:
            return true
        case .sessionApprove where sessionApprovedOps.contains(SessionApprovalKey(verb: .decrypt, keygrip: keygripHex)):
            return true
        case .sessionApprove, .perRequest:
            break
        }

        let resumer = ApprovalResumer()
        pendingResumers.append(resumer)
        let withdrawalCallback = onWithdrawal

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if resumer.attach(continuation) {
                    return
                }
                let request = GPGAgentApprovalRequest(
                    verb: .decrypt,
                    keyName: source.displayName,
                    fingerprint: source.displayFingerprint,
                    keygrip: keygripHex,
                    remoteHost: remoteHost,
                    sessionName: sessionName,
                    hashAlgorithm: nil,
                    hashPreview: "",
                    completion: { [weak self] approved in
                        resumer.resume(with: approved)
                        Task { @MainActor [weak self] in self?.removeResumer(resumer) }
                    }
                )
                resumer.setRequestID(request.id)
                Task { @MainActor in
                    if resumer.isResumed {
                        withdrawalCallback?(request.id)
                        return
                    }
                    self.pendingApproval = request
                    self.approvalRequestPublisher.send(request)
                }
            }
        } onCancel: {
            resumer.resume(with: false)
            if let id = resumer.requestID {
                withdrawalCallback?(id)
            }
        }
    }

    /// Reverse of the percent-escaping done by ``writeDataLine`` —
    /// the client uses the same encoding on the way back. `%0A`/`%0D`
    /// turn back into 0x0A/0x0D, `%25` into `%`. Any other `%XX`
    /// passes through as the two hex digits decoded literally (the
    /// Assuan dialect leaves room for future escape codes).
    ///
    /// Operates on raw bytes — D-line payloads are byte-oriented and
    /// must not be decoded via String.
    private func unescapeAssuanDataLine(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            let after = data.index(after: i)
            // 0x25 = '%' — start of a %XX escape.
            if b == 0x25,
               let third = data.index(i, offsetBy: 3, limitedBy: data.endIndex) {
                let h1 = data[after]
                let h2 = data[data.index(after: after)]
                if let hi = hexDigit(h1), let lo = hexDigit(h2) {
                    out.append(UInt8(hi << 4 | lo))
                    i = third
                    continue
                }
            }
            out.append(b)
            i = after
        }
        return out
    }

    /// ASCII hex digit byte → integer value. Supports both upper- and
    /// lowercase forms.
    private func hexDigit(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)        // 0-9
        case 0x41...0x46: return Int(byte - 0x41) + 10   // A-F
        case 0x61...0x66: return Int(byte - 0x61) + 10   // a-f
        default: return nil
        }
    }

    /// Maximum INQUIRE response we'll accept. 4 KiB is well above any
    /// realistic ECDH/RSA-2048 ciphertext (32 bytes ephemeral + ~32
    /// bytes wrapped session key, or a 256-byte RSA ciphertext +
    /// S-expression framing).
    private static let maxInquireLength = 4096

    // MARK: - Configuration gates

    /// Whether ``config`` permits using this particular key UUID for
    /// forwarding. Empty ``forwardedKeyIDs`` means "all keys" (both
    /// imported GPG keys and SSH keys with a cached keygrip).
    private func configurationAllowsKeyID(_ id: UUID) -> Bool {
        config.forwardedKeyIDs.isEmpty || config.forwardedKeyIDs.contains(id)
    }

    // MARK: - Approval flow

    private func requestApproval(
        for source: SigningSource,
        keygripHex: String,
        hash: Data,
        algorithm: GPGHashAlgorithm
    ) async -> Bool {
        switch config.approvalMode {
        case .autoApprove:
            return true
        case .sessionApprove where sessionApprovedOps.contains(SessionApprovalKey(verb: .sign, keygrip: keygripHex)):
            return true
        case .sessionApprove, .perRequest:
            break
        }

        // Wire the continuation through a single-shot, lock-protected
        // resumer so the UI completion and the cancellation handler
        // can race safely (whichever fires first wins; the loser is a
        // no-op). Without this, a session torn down while the alert
        // is still up would leave the continuation pending forever
        // and the per-channel serve task suspended.
        let resumer = ApprovalResumer()
        pendingResumers.append(resumer)

        // Capture nonisolated values for the onCancel closure (which
        // can't touch @MainActor `self` synchronously).
        let withdrawalCallback = onWithdrawal

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // If cancellation already won the race (onCancel fired
                // before this body ran because the task was already
                // cancelled), attach delivers `false` to the
                // continuation directly. Skip publishing — otherwise
                // the UI would surface a sheet for an approval the
                // caller has already given up on.
                if resumer.attach(continuation) {
                    return
                }
                let hashPreview = hash.prefix(8).map { String(format: "%02X", $0) }.joined()
                let request = GPGAgentApprovalRequest(
                    verb: .sign,
                    keyName: source.displayName,
                    fingerprint: source.displayFingerprint,
                    keygrip: keygripHex,
                    remoteHost: remoteHost,
                    sessionName: sessionName,
                    hashAlgorithm: algorithm,
                    hashPreview: hashPreview,
                    completion: { [weak self] approved in
                        resumer.resume(with: approved)
                        Task { @MainActor [weak self] in self?.removeResumer(resumer) }
                    }
                )
                resumer.setRequestID(request.id)
                Task { @MainActor in
                    // Re-check inside the actor — onCancel can fire
                    // between this Task being queued and run. Without
                    // the recheck we'd publish a request for a
                    // session that's already shutting down, leaving a
                    // stale prompt in MainView's queue.
                    if resumer.isResumed {
                        withdrawalCallback?(request.id)
                        return
                    }
                    self.pendingApproval = request
                    self.approvalRequestPublisher.send(request)
                }
            }
        } onCancel: {
            // Per-task — only resumes THIS task's continuation.
            resumer.resume(with: false)
            // Direct synchronous callback (Sendable @escaping
            // closure) — no async pump to drop the value if the
            // session is mid-cleanup. No-op when requestID is nil
            // (cancellation arrived before the request was
            // constructed — nothing was published, nothing to
            // withdraw).
            if let id = resumer.requestID {
                withdrawalCallback?(id)
            }
        }
    }

    /// Drain every in-flight approval continuation with `false`. Called
    /// from the session's disconnect / cleanup paths so the per-channel
    /// serve tasks unblock and exit instead of holding `self` alive via
    /// a never-resumed continuation.
    func cancelPendingApprovals() {
        let snapshot = pendingResumers
        pendingResumers.removeAll()
        for resumer in snapshot {
            resumer.resume(with: false)
            // Direct callback so withdrawals land even when the
            // session's approval-pump task has already been cancelled
            // earlier in cleanup. Idempotent on the UI side.
            if let id = resumer.requestID {
                onWithdrawal?(id)
            }
        }
        // Clear any visible/queued sheet so a teardown also dismisses
        // the approval UI rather than leaving a sheet up that resolves
        // to a request the serve task has already given up on.
        pendingApproval = nil
    }

    private func removeResumer(_ resumer: ApprovalResumer) {
        pendingResumers.removeAll(where: { $0 === resumer })
    }

    /// Resolve `--hash=<name>` tokens emitted by gpg-agent clients.
    /// Names match the lowercase form (`sha256`, `sha512`, etc.).
    /// Returns nil for anything we don't recognise — callers reject
    /// the SETHASH outright.
    private func parseHashOption(_ token: String) -> GPGHashAlgorithm? {
        guard let eq = token.firstIndex(of: "="), token.hasPrefix("--hash") else { return nil }
        let value = token[token.index(after: eq)...].lowercased()
        switch value {
        case "sha1":   return .sha1
        case "sha224": return .sha224
        case "sha256": return .sha256
        case "sha384": return .sha384
        case "sha512": return .sha512
        default:       return nil
        }
    }

    // MARK: - Assuan I/O helpers

    private func ok(_ stream: AsyncBytePipe) async throws {
        try await write(stream, "OK")
    }

    private func err(_ stream: AsyncBytePipe, code: Int, message: String) async throws {
        try await write(stream, "ERR \(code) \(message)")
    }

    private func write(_ stream: AsyncBytePipe, _ line: String) async throws {
        var bytes = Data(line.utf8)
        bytes.append(0x0A)
        try await stream.write(bytes)
    }

    /// `D` line payloads are byte-oriented but line-framed, so escape
    /// line breaks and `%` before writing them. Used for
    /// `PKSIGN`/`PKDECRYPT` replies and list data.
    private func writeDataLine(_ stream: AsyncBytePipe, payload: Data) async throws {
        try await writeDataLines(stream, payload: payload)
    }

    private func writeDataLines(_ stream: AsyncBytePipe, payload: Data) async throws {
        // A fully escaped byte expands to 3 bytes. Keep chunks well
        // below Assuan's normal line limit after the "D " prefix.
        let chunkSize = 240
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let end = payload.index(offset, offsetBy: chunkSize, limitedBy: payload.endIndex) ?? payload.endIndex
            try await writeEscapedDataLine(stream, payload: payload.subdata(in: offset..<end))
            offset = end
        }
    }

    private func writeEscapedDataLine(_ stream: AsyncBytePipe, payload: Data) async throws {
        var out = Data()
        out.append(0x44)  // 'D'
        out.append(0x20)  // ' '
        for byte in payload {
            switch byte {
            case 0x0A:
                out.append(contentsOf: [0x25, 0x30, 0x41])  // %0A
            case 0x0D:
                out.append(contentsOf: [0x25, 0x30, 0x44])  // %0D
            case 0x25:
                out.append(contentsOf: [0x25, 0x32, 0x35])  // %25
            default:
                out.append(byte)
            }
        }
        out.append(0x0A)
        try await stream.write(out)
    }
}

// MARK: - Assuan helpers

/// Per-connection state — what the remote has set via prior commands.
/// Lives outside the manager because Swift actors can't have mutating
/// methods on stored properties cleanly; carrying it as a value type
/// passed `inout` through the loop is simpler than wrapping it in
/// another actor.
private struct AssuanSession {
    var activeKeygrip: String?
    /// Tag identifying the source store + key UUID. The actual
    /// ``GPGAgentManager.SigningSource`` is re-resolved per PKSIGN
    /// using this tag and ``activeKeygrip`` — keeps this struct
    /// free of MainActor-isolated types and `Sendable` complications.
    var activeSourceTag: GPGAgentManager.SourceTag?
    var hash: Data?
    var hashAlgorithm: GPGHashAlgorithm?

    mutating func reset() {
        activeKeygrip = nil
        activeSourceTag = nil
        hash = nil
        hashAlgorithm = nil
    }

    /// Send the gpg-agent banner that real implementations open the
    /// connection with. Some gpg builds bail if they don't see this.
    func greet(stream: AsyncBytePipe) async {
        let banner = Data("OK Pleased to meet you\n".utf8)
        try? await stream.write(banner)
    }
}

/// Buffered line reader shared between ``GPGAgentManager/runLoop`` and
/// the individual command handlers — specifically, ``handlePKDECRYPT``
/// needs to read additional `D`/`END` lines from the same stream after
/// it sends an `INQUIRE`. Reference type because the buffered bytes
/// must persist across the multiple `await` points the consumer hits.
fileprivate final class AssuanReader {
    private let stream: AsyncBytePipe
    private var buffer = Data()

    init(stream: AsyncBytePipe) {
        self.stream = stream
    }

    /// Read one Assuan line (terminated by `\n`, with optional CR
    /// stripped by the parser). Returns nil on clean EOF.
    func readLine() async throws -> AssuanLine? {
        while true {
            if let lf = buffer.firstRange(of: Data([0x0A])) {
                let bytes = buffer.subdata(in: buffer.startIndex..<lf.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<lf.upperBound)
                return AssuanLine.parse(bytes)
            }
            guard let chunk = try await stream.read(maxBytes: 4096) else { return nil }
            buffer.append(chunk)
        }
    }
}

private struct AssuanLine {
    let verb: String
    let argument: String
    /// Raw bytes between the verb's trailing space and the end of the
    /// line, exactly as received. The `argument` String form is a
    /// UTF-8 decode of these bytes that's lossy for binary payloads;
    /// D-lines (INQUIRE response ciphertext, signed material, …) MUST
    /// use ``argumentBytes`` to avoid mangling 0x00/0x80+ octets.
    let argumentBytes: Data

    static func parse(_ bytes: Data) -> AssuanLine {
        // Strip optional trailing CR (clients may emit CRLF).
        var slice = bytes
        if let last = slice.last, last == 0x0D { slice.removeLast() }

        // Find the verb / argument boundary at the byte level. Verbs
        // are always ASCII per the Assuan spec, so UTF-8 round-trip
        // on the verb is safe; the argument may be raw binary.
        if let spaceIdx = slice.firstIndex(of: 0x20) {
            let verbBytes = slice[..<spaceIdx]
            let argBytes = Data(slice[slice.index(after: spaceIdx)...])
            let verb = String(data: verbBytes, encoding: .utf8) ?? ""
            // The String form is best-effort — invalid UTF-8 sequences
            // (common in binary D-line payloads) decode to a replacement
            // character. Consumers that need exact bytes use
            // `argumentBytes`.
            let argument = String(data: argBytes, encoding: .utf8) ?? ""
            return AssuanLine(verb: verb, argument: argument, argumentBytes: argBytes)
        }

        let verb = String(data: slice, encoding: .utf8) ?? ""
        return AssuanLine(verb: verb, argument: "", argumentBytes: Data())
    }
}

/// Lock-protected single-shot resumer that lets either the UI
/// completion or the cancellation handler resume an approval
/// continuation safely. Whichever fires first wins; subsequent calls
/// are no-ops. `@unchecked Sendable` because the NSLock guards every
/// mutation — `onCancel` from `withTaskCancellationHandler` runs off
/// the main actor, so the resumer can't be MainActor-isolated.
///
/// `nonisolated` is explicit because the project default would
/// otherwise pin every method to MainActor (under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) and the Sendable
/// completion/cancellation callbacks couldn't call `resume(with:)`
/// or read `requestID` without a synchronous-from-nonisolated
/// diagnostic.
nonisolated final class ApprovalResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resumed = false
    /// Value that `resume(with:)` was called with before `attach`
    /// happened. `withTaskCancellationHandler` runs `onCancel`
    /// concurrently with the operation body when the task was
    /// already cancelled, so resume can land before attach has the
    /// continuation. The pending value lets attach hand the result
    /// straight to the continuation in that case.
    private var pendingResult: Bool?
    /// UUID of the approval request once it's been built. Set by
    /// `setRequestID(_:)` after the request is constructed but before
    /// it's published — so the cancellation paths can name the
    /// request when telling the UI to drop it from the queue.
    private var _requestID: UUID?

    /// Returns `true` if a prior `resume` already won the race —
    /// caller should immediately stop setting up the request (no UI
    /// publish, no pending-approval mutation) because the continuation
    /// has already been completed with that earlier value.
    @discardableResult
    func attach(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(returning: pending)
            return true
        }
        self.continuation = continuation
        lock.unlock()
        return false
    }

    func resume(with value: Bool) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let cont = continuation
        continuation = nil
        if cont == nil {
            // attach hasn't happened yet — stash the value so the
            // upcoming attach delivers it.
            pendingResult = value
        }
        lock.unlock()
        cont?.resume(returning: value)
    }

    func setRequestID(_ id: UUID) {
        lock.lock()
        _requestID = id
        lock.unlock()
    }

    var requestID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return _requestID
    }

    var isResumed: Bool {
        lock.lock(); defer { lock.unlock() }
        return resumed
    }
}

/// Subset of the Assuan error codes we report back.
private enum AssuanError {
    static let generalError = 1
    static let notImplemented = 69
    static let invalidValue = 55
    static let canceled = 99
    static let noSecKey = 17
}
