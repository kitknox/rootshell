//
//  SSHKeyGPGBridge.swift
//  rootshell
//
//  Lets the GPG agent forwarding layer reuse existing SSH keys.
//  Computes a GPG-agent-compatible keygrip from the public material
//  inside an ``SSHPrivateKeyVariant`` for the algorithms GPG cares
//  about (Ed25519, ECDSA P-256, RSA), and signs over a precomputed
//  digest using the same primitives ``GPGSigner`` uses for imported
//  GPG keys.
//
//  Rationale: SSH and OpenPGP both ride Ed25519 / ECDSA / RSA at the
//  cryptographic layer. Users with an SSH key already have everything
//  they need to sign commits, packages, and arbitrary blobs via the
//  remote `gpg` client over the forwarded agent socket — without
//  having to re-export and re-import the same key in OpenPGP format.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import NIOCore
import NIOFoundationCompat
import Crypto
import Citadel
import NIOSSH

/// Pure cryptographic plumbing between SSH keys and the OpenPGP wire
/// format. `nonisolated` so the agent's `@MainActor` Assuan loop can
/// hop the heavy work (RSA decrypt, YubiKey NFC/USB I/O) off the UI
/// thread via `Task.detached`. The project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise pin
/// every static method here to main.
nonisolated enum SSHKeyGPGBridge {

    // MARK: - Keygrip

    /// Compute the GPG keygrip (40-char uppercase hex) for the public
    /// material of `variant`. Returns nil for key types we don't yet
    /// support for GPG signing (hardware keys, NIST P-384, NIST P-521).
    static func keygripHex(for variant: SSHPrivateKeyVariant, keyType: SSHKey.KeyType) -> String? {
        guard let (algorithm, publicMaterial) = openPGPPublicMaterial(for: variant, keyType: keyType) else {
            return nil
        }
        do {
            let grip = try Keygrip.compute(algorithm: algorithm, publicMaterial: publicMaterial)
            return GPGHex.encodeUpper(grip)
        } catch {
            return nil
        }
    }

    /// Compute the GPG keygrip for this key's *encryption* role
    /// (PKDECRYPT). For RSA and ECDSA P-256 this is identical to the
    /// signing keygrip — same modulus / curve params / public point,
    /// so the agent produces the same grip. For Ed25519 the grip
    /// differs: we derive the X25519 (cv25519) public point from the
    /// Ed25519 seed and compute the keygrip against the Montgomery
    /// curve params. Returns nil for keys we can't decrypt with
    /// (YubiKey, FIDO2, P-384/P-521).
    static func encryptionKeygripHex(for variant: SSHPrivateKeyVariant, keyType: SSHKey.KeyType) -> String? {
        guard let (algorithm, publicMaterial) = openPGPEncryptionPublicMaterial(
            for: variant, keyType: keyType
        ) else {
            return nil
        }
        do {
            let grip = try Keygrip.compute(algorithm: algorithm, publicMaterial: publicMaterial)
            return GPGHex.encodeUpper(grip)
        } catch {
            return nil
        }
    }

    /// Build the `(algorithm, publicMaterial)` pair that ``Keygrip``
    /// and ``GPGSigner`` consume. Public-only — the corresponding
    /// secret material is pulled out separately during signing so we
    /// can keep the biometric prompt scoped to the actual signing
    /// operation.
    static func openPGPPublicMaterial(
        for variant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType
    ) -> (OpenPGPAlgorithm, OpenPGPSubkey.PublicMaterial)? {
        switch variant {
        case .nioSSH(let nioKey):
            switch keyType {
            case .ed25519:
                guard let q = extractEd25519PublicKey(nioKey.publicKey) else { return nil }
                // OpenPGP EdDSA encoding wraps the 32-byte point with
                // a 0x40 prefix — see the eddsaLegacy branch in
                // Keygrip.swift for the shared rationale.
                var prefixed = Data([0x40])
                prefixed.append(q)
                return (.eddsaLegacy(.ed25519), .ec(q: prefixed))
            case .ecdsaP256:
                guard let q = extractECDSAPublicKey(nioKey.publicKey) else { return nil }
                return (.ecdsa(.p256), .ec(q: q))
            case .ecdsaP384, .ecdsaP521:
                // GPG agent forwarding theoretically supports these,
                // but GPGSigner doesn't have curve constants for them
                // yet — fall through.
                return nil
            default:
                return nil
            }

        case .rsa(let rsaKey):
            guard let pub = rsaKey.publicKey as? Insecure.RSA.PublicKey else { return nil }
            return (.rsa, .rsa(n: pub.modulusBytes, e: pub.publicExponentBytes))

        case .yubiKey(let ref):
            return openPGPPublicMaterialForYubiKey(reference: ref)

        case .appleFIDO2:
            // FIDO2/sk- keys produce CTAP2 signatures with attestation
            // and authenticator-data bound in; gpg has no protocol for
            // verifying those, so this path is fundamentally absent
            // (not just unwired).
            return nil
        case .secureEnclaveP256:
            // The enclave never exposes the scalar GPG's PKSIGN needs, so
            // Secure Enclave keys are never advertised as GPG identities.
            return nil
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent:
            // The ssh-agent protocol only produces SSH-style signatures;
            // GPG's PKSIGN/PKDECRYPT semantics are out of reach.
            return nil
        #endif
        }
    }

    /// Build the `(algorithm, publicMaterial)` pair for the
    /// *encryption* keygrip — same job as ``openPGPPublicMaterial(for:keyType:)``
    /// but routes Ed25519 through the Ed25519 → X25519 conversion so
    /// the resulting keygrip targets cv25519 (Montgomery form) rather
    /// than the Edwards-curve sign keygrip. RSA and ECDSA P-256 yield
    /// the same `(alg, mat)` pair as the signing variant because
    /// the keygrip hash doesn't see the algorithm name.
    static func openPGPEncryptionPublicMaterial(
        for variant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType
    ) -> (OpenPGPAlgorithm, OpenPGPSubkey.PublicMaterial)? {
        switch variant {
        case .nioSSH(let nioKey):
            switch keyType {
            case .ed25519:
                // Derive X25519 public point from the Ed25519 seed:
                //   1. expanded = SHA-512(seed)         → 64 bytes
                //   2. x25519_scalar = expanded[0..<32] (CryptoKit
                //      clamps internally on construction)
                //   3. x25519_pub = X25519(scalar)·BasePoint
                guard let seed = nioKey.ed25519PrivateKey?.rawRepresentation else { return nil }
                guard let xPub = deriveX25519PublicFromEd25519Seed(seed) else { return nil }
                // OpenPGP wire form for cv25519: 0x40 || 32 bytes
                var prefixed = Data([0x40])
                prefixed.append(xPub)
                return (.ecdh(.cv25519), .ec(q: prefixed))
            case .ecdsaP256:
                // Same curve, same public point — same keygrip works
                // for ECDSA (sign) and ECDH (encrypt).
                guard let q = extractECDSAPublicKey(nioKey.publicKey) else { return nil }
                return (.ecdh(.p256), .ec(q: q))
            case .ecdsaP384, .ecdsaP521:
                return nil
            default:
                return nil
            }

        case .rsa(let rsaKey):
            guard let pub = rsaKey.publicKey as? Insecure.RSA.PublicKey else { return nil }
            // RSA keygrip is computed over `n` only — sign and encrypt
            // share the same grip.
            return (.rsa, .rsa(n: pub.modulusBytes, e: pub.publicExponentBytes))

        case .yubiKey(let ref):
            // RSA slots: same (n, e) shape as the signing role — the
            // GPG keygrip is shared. ECDSA P-256 slots likewise reuse
            // the same point. Ed25519 PIV slots are curve-locked to
            // the Edwards form and can't perform X25519, so they have
            // no encryption identity.
            switch ref.algorithm {
            case .rsa2048, .rsa4096:
                guard let (n, e) = parseSSHRSAPublicBlob(ref.publicKeyBlob) else { return nil }
                return (.rsa, .rsa(n: n, e: e))
            case .ecdsaP256:
                guard let q = parseSSHECDSAPublicBlob(ref.publicKeyBlob) else { return nil }
                return (.ecdh(.p256), .ec(q: q))
            case .ecdsaP384, .ed25519, .mldsa44, .mldsa65, .mldsa87:
                return nil
            }

        case .appleFIDO2:
            return nil
        case .secureEnclaveP256:
            return nil
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent:
            return nil
        #endif
        }
    }

    /// Compute the v4 OpenPGP fingerprint of the ECDH subkey we'd
    /// emit at export time for this SSH key. Used by the PKDECRYPT
    /// path so the KDF's recipient-fingerprint input matches what the
    /// remote used at encryption time (the remote saw the same
    /// fingerprint when it imported the exported public-key block).
    ///
    /// Returns nil for key types we don't bridge to ECDH (hardware-
    /// only keys, P-384/P-521).
    static func openPGPEncryptionFingerprint(
        for variant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        ctime: UInt32
    ) -> Data? {
        guard let (algorithm, publicMaterial) = openPGPEncryptionPublicMaterial(
            for: variant, keyType: keyType
        ) else {
            return nil
        }
        let body = encodeECDHSubkeyPacketBody(
            ctime: ctime,
            algorithm: algorithm,
            publicMaterial: publicMaterial
        )
        return openPGPV4Fingerprint(packetBody: body)
    }

    /// Build the public-key packet body for an ECDH subkey. Mirrors
    /// what ``OpenPGPPublicKeyExport`` emits at export time — keep
    /// this in sync with that file's `buildECDHSubkeyPacketBody` so
    /// import-time and decrypt-time fingerprints agree byte-for-byte.
    private static func encodeECDHSubkeyPacketBody(
        ctime: UInt32,
        algorithm: OpenPGPAlgorithm,
        publicMaterial: OpenPGPSubkey.PublicMaterial
    ) -> Data {
        var body = Data()
        body.append(0x04)  // version
        // 4-byte BE ctime
        body.append(UInt8((ctime >> 24) & 0xFF))
        body.append(UInt8((ctime >> 16) & 0xFF))
        body.append(UInt8((ctime >> 8) & 0xFF))
        body.append(UInt8(ctime & 0xFF))
        // Algorithm byte
        switch algorithm {
        case .ecdh: body.append(18)
        case .rsa:  body.append(1)
        default:    body.append(0)  // Unreachable for encryption keys.
        }
        switch (algorithm, publicMaterial) {
        case (.ecdh(let curve), .ec(let q)):
            let oid: Data
            switch curve {
            case .p256:
                oid = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
            case .cv25519:
                oid = Data([0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01])
            case .ed25519:
                oid = Data()  // Unreachable
            }
            body.append(UInt8(oid.count))
            body.append(oid)
            body.append(encodeMPI(q))
            // KDF params block (RFC 9580 §5.5.5.6): 03 01 08 07
            // (SHA-256 + AES-128). Matches the values emitted by
            // ``OpenPGPPublicKeyExport/buildECDHSubkeyPacketBody``.
            body.append(0x03)
            body.append(0x01)
            body.append(0x08)
            body.append(0x07)
        case (.rsa, .rsa(let n, let e)):
            body.append(encodeMPI(n))
            body.append(encodeMPI(e))
        default:
            break
        }
        return body
    }

    /// SHA-1 over `0x99 || len2(body) || body` per RFC 9580 §5.5.4.
    private static func openPGPV4Fingerprint(packetBody: Data) -> Data {
        var input = Data()
        input.append(0x99)
        input.append(UInt8((packetBody.count >> 8) & 0xFF))
        input.append(UInt8(packetBody.count & 0xFF))
        input.append(packetBody)
        return Data(Insecure.SHA1.hash(data: input))
    }

    /// OpenPGP MPI encoding: 2-byte BE bit length, then ceil(bits/8)
    /// bytes. Leading zeros stripped first so the bit count is
    /// canonical. Matches what the exporter emits.
    private static func encodeMPI(_ value: Data) -> Data {
        var trimmed = value
        while trimmed.count > 1, trimmed.first == 0 {
            trimmed = trimmed.subdata(in: trimmed.index(after: trimmed.startIndex)..<trimmed.endIndex)
        }
        if trimmed.isEmpty {
            return Data([0x00, 0x00])
        }
        let firstByte = trimmed.first!
        var topBit = 8
        for shift in stride(from: 7, through: 0, by: -1) {
            if (firstByte >> shift) & 0x01 == 1 {
                topBit = shift + 1
                break
            }
        }
        let bitLen = (trimmed.count - 1) * 8 + topBit
        var out = Data()
        out.append(UInt8((bitLen >> 8) & 0xFF))
        out.append(UInt8(bitLen & 0xFF))
        out.append(trimmed)
        return out
    }

    /// Convert an Ed25519 seed (32 bytes, the canonical "raw" Ed25519
    /// secret) to the corresponding X25519 public point. Uses
    /// CryptoKit's `Curve25519.KeyAgreement.PrivateKey`, which clamps
    /// the scalar per RFC 7748 §5 before the scalar multiplication.
    private static func deriveX25519PublicFromEd25519Seed(_ seed: Data) -> Data? {
        guard seed.count == 32 else { return nil }
        let expanded = SHA512.hash(data: seed)
        let scalarBytes = Data(expanded).prefix(32)
        do {
            let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalarBytes)
            return priv.publicKey.rawRepresentation
        } catch {
            return nil
        }
    }

    /// YubiKey PIV: the cached `publicKeyBlob` is the SSH wire-format
    /// public key produced when the PIV cert was imported. Parse it
    /// using the same readers as the software-key path, then build
    /// the OpenPGP-shaped public material per algorithm.
    private static func openPGPPublicMaterialForYubiKey(
        reference: YubiKeyReference
    ) -> (OpenPGPAlgorithm, OpenPGPSubkey.PublicMaterial)? {
        switch reference.algorithm {
        case .rsa2048, .rsa4096:
            guard let (n, e) = parseSSHRSAPublicBlob(reference.publicKeyBlob) else { return nil }
            return (.rsa, .rsa(n: n, e: e))
        case .ecdsaP256:
            guard let q = parseSSHECDSAPublicBlob(reference.publicKeyBlob) else { return nil }
            return (.ecdsa(.p256), .ec(q: q))
        case .ecdsaP384:
            // GPG keygrip + sig-val for P-384 isn't wired in
            // ``Keygrip`` / ``CanonicalSExpression`` yet; fall through.
            return nil
        case .ed25519:
            guard let q = parseSSHEd25519PublicBlob(reference.publicKeyBlob) else { return nil }
            var prefixed = Data([0x40])
            prefixed.append(q)
            return (.eddsaLegacy(.ed25519), .ec(q: prefixed))
        case .mldsa44, .mldsa65, .mldsa87:
            // No OpenPGP mapping, same as software ML-DSA keys.
            return nil
        }
    }

    /// Public-blob backfill for the *encryption* keygrip. Mirrors
    /// ``keygripHexFromPublicKeyBlob(_:keyType:)`` for RSA and ECDSA
    /// P-256 — both produce the same keygrip for sign and encrypt
    /// because the keygrip hash covers curve params + public point
    /// only, not the algorithm name. Returns nil for Ed25519 (the
    /// X25519 public point isn't derivable from the Ed25519 public
    /// blob without field-arithmetic that CryptoKit doesn't expose —
    /// Ed25519 keys backfill their encryption keygrip lazily on first
    /// private-key load).
    static func encryptionKeygripHexFromPublicKeyBlob(
        _ blob: Data,
        keyType: SSHKey.KeyType
    ) -> String? {
        let payload: (OpenPGPAlgorithm, OpenPGPSubkey.PublicMaterial)?
        switch keyType {
        case .rsa, .yubiKeyPIV:
            if let (n, e) = parseSSHRSAPublicBlob(blob) {
                payload = (.rsa, .rsa(n: n, e: e))
            } else {
                payload = nil
            }
        case .ecdsaP256:
            if let q = parseSSHECDSAPublicBlob(blob) {
                payload = (.ecdh(.p256), .ec(q: q))
            } else {
                payload = nil
            }
        case .ed25519,
             .ecdsaP384, .ecdsaP521, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256, .externalAgent,
             .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
            payload = nil
        }
        guard let (algorithm, publicMaterial) = payload else { return nil }
        do {
            let grip = try Keygrip.compute(algorithm: algorithm, publicMaterial: publicMaterial)
            return GPGHex.encodeUpper(grip)
        } catch {
            return nil
        }
    }

    /// Compute a keygrip purely from a cached SSH wire-format public
    /// key blob — no Keychain access, no private-key load required.
    /// Used by the one-time keygrip migration (`SSHKeyManager.init`)
    /// to fix keygrips computed before the keygrip-format bugs were
    /// caught. Returns nil when we don't have a Keygrip mapping for
    /// the key type (hardware FIDO2, ECDSA P-384/P-521, etc).
    static func keygripHexFromPublicKeyBlob(
        _ blob: Data,
        keyType: SSHKey.KeyType
    ) -> String? {
        let payload: (OpenPGPAlgorithm, OpenPGPSubkey.PublicMaterial)?
        switch keyType {
        case .rsa, .yubiKeyPIV:
            // Both paths use ssh-rsa wire format.
            if let (n, e) = parseSSHRSAPublicBlob(blob) {
                payload = (.rsa, .rsa(n: n, e: e))
            } else {
                payload = nil
            }
        case .ed25519:
            if let q = parseSSHEd25519PublicBlob(blob) {
                var prefixed = Data([0x40])
                prefixed.append(q)
                payload = (.eddsaLegacy(.ed25519), .ec(q: prefixed))
            } else {
                payload = nil
            }
        case .ecdsaP256:
            if let q = parseSSHECDSAPublicBlob(blob) {
                payload = (.ecdsa(.p256), .ec(q: q))
            } else {
                payload = nil
            }
        case .ecdsaP384, .ecdsaP521, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256, .externalAgent,
             .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
            payload = nil
        }
        guard let (algorithm, publicMaterial) = payload else { return nil }
        do {
            let grip = try Keygrip.compute(algorithm: algorithm, publicMaterial: publicMaterial)
            return GPGHex.encodeUpper(grip)
        } catch {
            return nil
        }
    }

    // MARK: - Signing

    /// Raw signature output, free of any wire-format wrapping. The
    /// agent-forwarding path wraps these as a canonical S-expression
    /// (`(sig-val (eddsa (r ...) (s ...)))` etc.); the OpenPGP-export
    /// path emits them as MPIs inside a signature packet. Both
    /// callers consume the same struct so the actual key-material
    /// access lives in one place.
    enum RawSignature: Sendable, Hashable {
        case ed25519(r: Data, s: Data)
        case ecdsa(r: Data, s: Data)
        case rsa(s: Data)
    }

    /// Sign `hash` with the SSH key's underlying material, returning
    /// raw signature components. Triggers biometric / NFC / YubiKey
    /// PIN as appropriate (`SSHKeyManager`-style auth happens at the
    /// load-and-cache layer above this method).
    static func signRaw(
        variant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        hash: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) async throws -> RawSignature {
        switch variant {
        case .nioSSH(let nioKey):
            switch keyType {
            case .ed25519:
                guard let priv = nioKey.ed25519PrivateKey else { throw GPGSignError.malformedKey }
                let sig = try priv.signature(for: hash)
                guard sig.count == 64 else { throw GPGSignError.malformedSignature }
                return .ed25519(r: Data(sig.prefix(32)), s: Data(sig.suffix(32)))
            case .ecdsaP256:
                guard let priv = nioKey.p256PrivateKey else { throw GPGSignError.malformedKey }
                guard hash.count == 32 else { throw GPGSignError.malformedKey }
                let digest = Hash32(bytes: hash)
                let sig = try priv.signature(for: digest)
                let raw = sig.rawRepresentation
                guard raw.count == 64 else { throw GPGSignError.malformedSignature }
                return .ecdsa(r: Data(raw.prefix(32)), s: Data(raw.suffix(32)))
            case .ecdsaP384, .ecdsaP521,
                 .rsa, .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256, .externalAgent,
                 .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
                throw GPGSignError.unsupportedAlgorithm("SSH key type \(keyType.rawValue)")
            }

        case .rsa(let rsaKey):
            let citadelHash: Insecure.RSA.PrivateKey.PrecomputedHashAlgorithm
            switch hashAlgorithm {
            case .sha1: citadelHash = .sha1
            case .sha224: citadelHash = .sha224
            case .sha256: citadelHash = .sha256
            case .sha384: citadelHash = .sha384
            case .sha512: citadelHash = .sha512
            case .unknown(let id):
                throw GPGSignError.unsupportedAlgorithm("hash id \(id) for RSA")
            }
            let signature = try rsaKey.signature(forPrecomputedDigest: hash, hashAlgorithm: citadelHash)
            guard let pub = rsaKey.publicKey as? Insecure.RSA.PublicKey else {
                throw GPGSignError.malformedKey
            }
            let modulusByteLength = pub.modulusBytes.count
            let padded: Data
            if signature.rawRepresentation.count >= modulusByteLength {
                padded = signature.rawRepresentation.suffix(modulusByteLength)
            } else {
                var p = Data(repeating: 0, count: modulusByteLength - signature.rawRepresentation.count)
                p.append(signature.rawRepresentation)
                padded = p
            }
            return .rsa(s: padded)

        case .yubiKey(let ref):
            return try await signRawWithYubiKey(reference: ref, hash: hash, hashAlgorithm: hashAlgorithm)

        case .appleFIDO2:
            throw GPGSignError.unsupportedAlgorithm("FIDO2/sk- key")
        case .secureEnclaveP256:
            throw GPGSignError.unsupportedAlgorithm("Secure Enclave P-256 key")
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent:
            throw GPGSignError.unsupportedAlgorithm("external SSH agent key")
        #endif
        }
    }

    /// Decrypt an Assuan-style `(enc-val …)` ciphertext using an
    /// SSH key as the underlying secret material. The reply payload is
    /// returned raw (caller wraps it in the `(value …)` reply).
    ///
    /// Coverage:
    ///   * Ed25519 — converts the seed to an X25519 scalar via
    ///     SHA-512(seed)[0..<32], then returns either the shared
    ///     secret or the locally unwrapped session frame.
    ///   * ECDSA P-256 — same reply-mode split with
    ///     `P256.KeyAgreement.PrivateKey`.
    ///   * RSA / YubiKey / FIDO2 — currently throws unsupported.
    ///     SSH RSA → GPG decrypt needs raw modular exponentiation
    ///     access that Citadel's public API doesn't expose; users
    ///     who need this can import the same key as an OpenPGP
    ///     secret-key export and decrypt with that.
    static func decryptRaw(
        variant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        encValSExpr: SExpr,
        primaryFingerprint: Data,
        replyMode: GPGDecryptor.ReplyMode = .unwrappedSessionKey
    ) async throws -> Data {
        // Caller passes the full `(enc-val (algo …))` envelope —
        // extract the inner once so the case-specific code can match
        // on the algorithm head directly. ``GPGDecryptor.decrypt``
        // performs its own outer-shape validation, so the synthetic-
        // subkey paths below pass the envelope through unchanged.
        guard case .list(let items) = encValSExpr,
              items.count >= 2,
              items[0].atomString == "enc-val" else {
            throw GPGDecryptError.malformedCiphertext("missing enc-val wrapper")
        }
        let inner = items[1]

        switch variant {
        case .nioSSH(let nioKey):
            switch keyType {
            case .ed25519:
                guard let seed = nioKey.ed25519PrivateKey?.rawRepresentation else {
                    throw GPGDecryptError.malformedKey
                }
                // Expand the Ed25519 seed to derive the X25519 scalar.
                // The matching public point is computed by CryptoKit
                // internally; we just need the scalar.
                let expanded = SHA512.hash(data: seed)
                let xScalar = Data(expanded).prefix(32)
                let synthetic = OpenPGPSubkey(
                    algorithm: .x25519Native,
                    creationTime: 0,
                    publicMaterial: .ec(q: Data()),
                    secretMaterial: .ec(d: xScalar),
                    fingerprint: Data(),
                    keygrip: Data(),
                    isPrimary: true,
                    capability: .encrypt,
                    keyFlags: nil,
                    kdfParams: nil
                )
                return try GPGDecryptor.decrypt(
                    subkey: synthetic,
                    encValSExpr: encValSExpr,
                    primaryFingerprint: primaryFingerprint,
                    replyMode: replyMode
                )
            case .ecdsaP256:
                guard let priv = nioKey.p256PrivateKey else {
                    throw GPGDecryptError.malformedKey
                }
                let scalar = priv.rawRepresentation
                let synthetic = OpenPGPSubkey(
                    algorithm: .ecdh(.p256),
                    creationTime: 0,
                    publicMaterial: .ec(q: Data()),
                    secretMaterial: .ec(d: scalar),
                    fingerprint: Data(),
                    keygrip: Data(),
                    isPrimary: true,
                    capability: .encrypt,
                    keyFlags: nil,
                    kdfParams: nil
                )
                return try GPGDecryptor.decrypt(
                    subkey: synthetic,
                    encValSExpr: encValSExpr,
                    primaryFingerprint: primaryFingerprint,
                    replyMode: replyMode
                )
            case .ecdsaP384, .ecdsaP521,
                 .rsa, .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256, .externalAgent,
                 .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
                throw GPGDecryptError.unsupportedAlgorithm("SSH key type \(keyType.rawValue)")
            }

        case .rsa(let rsaKey):
            // Pull the `(a <ciphertext-MPI>)` value out and hand it
            // to Citadel's raw decrypt. The ciphertext arrives as a
            // big-endian MPI; left-pad to the modulus byte length so
            // BoringSSL's PKCS#1 unpad sees a properly-sized block.
            guard inner.isList(named: "rsa"),
                  let aPair = inner.firstChild(named: "a"),
                  let cipherBytes = aPair.pairValue else {
                throw GPGDecryptError.malformedCiphertext("rsa enc-val missing (a …)")
            }
            guard let pub = rsaKey.publicKey as? Insecure.RSA.PublicKey else {
                throw GPGDecryptError.malformedKey
            }
            let modulusByteLen = stripLeadingZerosLocal(pub.modulusBytes).count
            let ciphertext = leftPadLocal(cipherBytes, toCount: modulusByteLen)
            do {
                return try rsaKey.decryptPKCS1v15(ciphertext)
            } catch {
                throw GPGDecryptError.aesUnwrapFailed("RSA decrypt failed: \(error.localizedDescription)")
            }

        case .yubiKey(let ref):
            return try await decryptWithYubiKey(
                reference: ref,
                encValInner: inner,
                primaryFingerprint: primaryFingerprint,
                replyMode: replyMode
            )

        case .appleFIDO2:
            throw GPGDecryptError.unsupportedAlgorithm("FIDO2/sk- decrypt is not supported")
        case .secureEnclaveP256:
            throw GPGDecryptError.unsupportedAlgorithm("Secure Enclave P-256 decrypt is not supported")
        #if targetEnvironment(macCatalyst) && STANDALONE
        case .externalAgent:
            throw GPGDecryptError.unsupportedAlgorithm("external SSH agent decrypt is not supported")
        #endif
        }
    }

    /// Wrap ``signRaw`` output as the canonical S-expression payload
    /// the GPG agent's `PKSIGN` reply needs. Kept as the existing
    /// entry point so callers that want the wire format don't have to
    /// know about the raw struct.
    static func sign(
        variant: SSHPrivateKeyVariant,
        keyType: SSHKey.KeyType,
        hash: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) async throws -> Data {
        let raw = try await signRaw(
            variant: variant, keyType: keyType,
            hash: hash, hashAlgorithm: hashAlgorithm
        )
        switch raw {
        case .ed25519(let r, let s):
            return CanonicalSExpression.eddsaSigVal(r: r, s: s)
        case .ecdsa(let r, let s):
            return CanonicalSExpression.ecdsaSigVal(
                r: leftPad(r, toCount: 32),
                s: leftPad(s, toCount: 32)
            )
        case .rsa(let s):
            return CanonicalSExpression.rsaSigVal(s: s)
        }
    }

    private static func leftPad(_ data: Data, toCount count: Int) -> Data {
        if data.count >= count { return data.suffix(count) }
        var padded = Data(repeating: 0, count: count - data.count)
        padded.append(data)
        return padded
    }

    /// File-local copy of leftPad/stripLeadingZeros. The existing
    /// `leftPad(_:toCount:)` is private to the signing path's enum
    /// scope; the decryption path lives at the bridge level so it
    /// needs its own copy. Cheap and self-contained.
    fileprivate static func leftPadLocal(_ data: Data, toCount count: Int) -> Data {
        if data.count >= count { return data.suffix(count) }
        var padded = Data(repeating: 0, count: count - data.count)
        padded.append(data)
        return padded
    }

    fileprivate static func stripLeadingZerosLocal(_ data: Data) -> Data {
        var slice = data
        while slice.count > 1, slice.first == 0x00 {
            slice = slice.subdata(in: slice.index(after: slice.startIndex)..<slice.endIndex)
        }
        return slice
    }

    // MARK: - YubiKey PIV decrypt

    /// Drive YubiKey PIV decryption through ``YubiKeySigner``. The
    /// flow mirrors the signing path: lock the YubiKey, ensure PIN /
    /// touch, perform the operation via the appropriate primitive,
    /// release.
    ///
    /// Algorithms:
    /// * RSA: card runs `c^d mod n` and strips PKCS#1 v1.5 padding
    ///   itself (we ask for the `.pkcs1v15` variant of the YubiKit
    ///   decrypt method); the returned bytes are the OpenPGP session-
    ///   key wrapping that gpg consumes.
    /// * ECDH P-256: card runs ECDH key agreement (DERIVE), returning
    ///   the 32-byte X coordinate of `d·E`. We then apply the
    ///   OpenPGP ECDH KDF + AES Key Unwrap locally to recover the
    ///   session key.
    /// * Ed25519: PIV slots are curve-locked to the Edwards form, so
    ///   the card can't do X25519 — surface as unsupported.
    private static func decryptWithYubiKey(
        reference: YubiKeyReference,
        encValInner: SExpr,
        primaryFingerprint: Data,
        replyMode: GPGDecryptor.ReplyMode
    ) async throws -> Data {
        guard let slot = reference.pivSlot else {
            throw GPGDecryptError.malformedKey
        }

        switch reference.algorithm {
        case .rsa2048, .rsa4096:
            // Extract ciphertext MPI from (rsa (a <bytes>)) and left-
            // pad to the modulus length.
            guard encValInner.isList(named: "rsa"),
                  let aPair = encValInner.firstChild(named: "a"),
                  let cipherBytes = aPair.pairValue else {
                throw GPGDecryptError.malformedCiphertext("rsa enc-val missing (a …)")
            }
            let modulusByteLen = (reference.algorithm == .rsa2048) ? 256 : 512
            let ciphertext = leftPadLocal(cipherBytes, toCount: modulusByteLen)
            do {
                return try await YubiKeySigner.shared.decryptWithPIV(
                    serialNumber: reference.serialNumber,
                    slot: slot,
                    algorithm: reference.algorithm,
                    ciphertext: ciphertext
                )
            } catch {
                throw GPGDecryptError.aesUnwrapFailed("YubiKey RSA decrypt failed: \(error.localizedDescription)")
            }

        case .ecdsaP256:
            // Pull the 65-byte uncompressed ephemeral public point
            // out of (ecdh|ecc (e …)) and ask the card to do the
            // ECDH operation. The returned 32 bytes are the X
            // coordinate of d·E, which we feed into the OpenPGP KDF.
            let isECDH = encValInner.isList(named: "ecdh") || encValInner.isList(named: "ecc")
            guard isECDH else {
                throw GPGDecryptError.malformedCiphertext("expected ecdh/ecc inner expression")
            }
            guard let ePair = encValInner.firstChild(named: "e"),
                  let ephemeral = ePair.pairValue,
                  ephemeral.count == 65, ephemeral.first == 0x04 else {
                throw GPGDecryptError.malformedCiphertext("expected 65-byte uncompressed P-256 ephemeral")
            }
            guard let sPair = encValInner.firstChild(named: "s"),
                  let wrappedRaw = sPair.pairValue else {
                throw GPGDecryptError.malformedCiphertext("missing (s …)")
            }

            let shared: Data
            do {
                shared = try await YubiKeySigner.shared.deriveSharedSecretWithPIV(
                    serialNumber: reference.serialNumber,
                    slot: slot,
                    algorithm: reference.algorithm,
                    peerPublicKey: ephemeral
                )
            } catch {
                throw GPGDecryptError.kdfFailed("YubiKey ECDH failed: \(error.localizedDescription)")
            }
            if replyMode == .legacyECDHSharedSecret {
                return shared
            }

            // OpenPGP KDF + AES unwrap. Default to SHA-256 + AES-128
            // since the SSH-key export pins these values; cv25519
            // and P-256 use the same defaults.
            let curveOID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
            let kek: Data
            do {
                kek = try OpenPGPECDH.deriveKEK(
                    sharedSecret: shared,
                    kdfHashAlgo: OpenPGPECDH.defaultHashAlgo,
                    kekAlgo: OpenPGPECDH.defaultKEKAlgo,
                    curveOID: curveOID,
                    recipientFingerprint: primaryFingerprint
                )
            } catch {
                throw GPGDecryptError.kdfFailed(error.localizedDescription)
            }
            let wrapped: Data
            if let first = wrappedRaw.first, Int(first) == wrappedRaw.count - 1 {
                wrapped = Data(wrappedRaw.dropFirst())
            } else {
                wrapped = wrappedRaw
            }
            do {
                return try AESKeyUnwrap.unwrap(wrapped, kek: kek)
            } catch {
                throw GPGDecryptError.aesUnwrapFailed(error.localizedDescription)
            }

        case .ecdsaP384:
            throw GPGDecryptError.unsupportedAlgorithm("YubiKey P-384 decrypt not supported")
        case .ed25519:
            throw GPGDecryptError.unsupportedAlgorithm("YubiKey Ed25519 PIV slot can't perform X25519")
        case .mldsa44, .mldsa65, .mldsa87:
            throw GPGDecryptError.unsupportedAlgorithm("YubiKey ML-DSA PIV slot can't decrypt")
        }
    }

    /// Drive YubiKey PIV signing through ``YubiKeySigner/signWithPIVPrehashed``
    /// and return raw signature components. Requires a PIV slot —
    /// yubikey references without one (e.g. FIDO2 PIV-style) can't
    /// be signed this way.
    private static func signRawWithYubiKey(
        reference: YubiKeyReference,
        hash: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) async throws -> RawSignature {
        guard let slot = reference.pivSlot else {
            throw GPGSignError.malformedKey
        }
        let raw = try await YubiKeySigner.shared.signWithPIVPrehashed(
            serialNumber: reference.serialNumber,
            slot: slot,
            algorithm: reference.algorithm,
            digest: hash,
            hashAlgorithm: hashAlgorithm
        )
        switch reference.algorithm {
        case .ed25519:
            guard raw.count == 64 else { throw GPGSignError.malformedSignature }
            return .ed25519(r: Data(raw.prefix(32)), s: Data(raw.suffix(32)))
        case .ecdsaP256:
            let (r, s) = try parseECDSADER(raw)
            return .ecdsa(r: leftPad(r, toCount: 32), s: leftPad(s, toCount: 32))
        case .ecdsaP384:
            throw GPGSignError.unsupportedAlgorithm("ECDSA P-384")
        case .mldsa44, .mldsa65, .mldsa87:
            throw GPGSignError.unsupportedAlgorithm(reference.algorithm.rawValue)
        case .rsa2048, .rsa4096:
            // YubiKey RSA `.raw` returns the modulus-width signature
            // directly.
            return .rsa(s: raw)
        }
    }

    /// Parse `SEQUENCE { r INTEGER, s INTEGER }` — same shape as the
    /// helper in ``GPGSigner`` but local to avoid pulling that
    /// module's private extension into scope.
    private static func parseECDSADER(_ data: Data) throws -> (r: Data, s: Data) {
        var idx = data.startIndex
        func readByte() throws -> UInt8 {
            guard idx < data.endIndex else { throw GPGSignError.malformedSignature }
            let b = data[idx]; idx = data.index(after: idx); return b
        }
        func readLength() throws -> Int {
            let first = try readByte()
            if first & 0x80 == 0 { return Int(first) }
            let n = Int(first & 0x7F)
            guard n > 0 && n <= 4 else { throw GPGSignError.malformedSignature }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(try readByte()) }
            return v
        }
        func readBytes(_ count: Int) throws -> Data {
            guard let end = data.index(idx, offsetBy: count, limitedBy: data.endIndex) else {
                throw GPGSignError.malformedSignature
            }
            let slice = data.subdata(in: idx..<end)
            idx = end
            return slice
        }
        guard try readByte() == 0x30 else { throw GPGSignError.malformedSignature }
        _ = try readLength()
        guard try readByte() == 0x02 else { throw GPGSignError.malformedSignature }
        let rLen = try readLength()
        let r = try readBytes(rLen)
        guard try readByte() == 0x02 else { throw GPGSignError.malformedSignature }
        let sLen = try readLength()
        let s = try readBytes(sLen)
        // Strip ASN.1 sign byte (leading 0x00 added when high bit is set).
        func stripSign(_ x: Data) -> Data {
            if let first = x.first, first == 0x00, x.count > 1 {
                return x.subdata(in: x.index(after: x.startIndex)..<x.endIndex)
            }
            return x
        }
        return (stripSign(r), stripSign(s))
    }

    // MARK: - SSH public-key bytes extraction
    //
    // Mirrors the helpers in ``SSHAgentSigner`` — same parse logic,
    // duplicated here so the GPG bridge has no dependency on the
    // SSH-agent code. Cheap (one allocation, one base64 decode, two
    // length-prefixed reads); runs at most once per SSH key during
    // backfill.

    private static func extractEd25519PublicKey(_ publicKey: NIOSSHPublicKey) -> Data? {
        let openSSHString = String(openSSHPublicKey: publicKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2,
              let blob = Data(base64Encoded: String(components[1])) else {
            return nil
        }
        var buffer = ByteBuffer(data: blob)
        _ = readSSHString(&buffer)
        guard let pubBuf = readSSHBuffer(&buffer) else { return nil }
        return pubBuf.getData(at: pubBuf.readerIndex, length: pubBuf.readableBytes)
    }

    private static func extractECDSAPublicKey(_ publicKey: NIOSSHPublicKey) -> Data? {
        let openSSHString = String(openSSHPublicKey: publicKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2,
              let blob = Data(base64Encoded: String(components[1])) else {
            return nil
        }
        var buffer = ByteBuffer(data: blob)
        _ = readSSHString(&buffer)
        _ = readSSHString(&buffer)
        guard let pubBuf = readSSHBuffer(&buffer) else { return nil }
        return pubBuf.getData(at: pubBuf.readerIndex, length: pubBuf.readableBytes)
    }

    private static func readSSHString(_ buffer: inout ByteBuffer) -> String? {
        guard let length: UInt32 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(length)) else {
            return nil
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func readSSHBuffer(_ buffer: inout ByteBuffer) -> ByteBuffer? {
        guard let length: UInt32 = buffer.readInteger() else { return nil }
        return buffer.readSlice(length: Int(length))
    }

    // MARK: - YubiKey publicKeyBlob parsers
    //
    // The PIV import flow stores keys in SSH wire format. Parse them
    // directly here so YubiKey-side keygrip + signing don't have to
    // re-derive material through swift-crypto wrappers (the secret
    // material isn't on device anyway).

    /// `<len>ssh-rsa<len><mpint e><len><mpint n>` → `(e, n)`.
    fileprivate static func parseSSHRSAPublicBlob(_ blob: Data) -> (n: Data, e: Data)? {
        var buffer = ByteBuffer(data: blob)
        _ = readSSHString(&buffer)  // "ssh-rsa"
        guard let eBuf = readSSHBuffer(&buffer),
              let nBuf = readSSHBuffer(&buffer) else {
            return nil
        }
        let e = eBuf.getData(at: eBuf.readerIndex, length: eBuf.readableBytes) ?? Data()
        let n = nBuf.getData(at: nBuf.readerIndex, length: nBuf.readableBytes) ?? Data()
        return (n, e)
    }

    /// `<len>ecdsa-sha2-nistp*<len>nistp*<len><uncompressed point>` → point.
    fileprivate static func parseSSHECDSAPublicBlob(_ blob: Data) -> Data? {
        var buffer = ByteBuffer(data: blob)
        _ = readSSHString(&buffer)  // "ecdsa-sha2-nistpXXX"
        _ = readSSHString(&buffer)  // curve identifier
        guard let pubBuf = readSSHBuffer(&buffer) else { return nil }
        return pubBuf.getData(at: pubBuf.readerIndex, length: pubBuf.readableBytes)
    }

    /// `<len>ssh-ed25519<len><32-byte point>` → raw 32 bytes.
    fileprivate static func parseSSHEd25519PublicBlob(_ blob: Data) -> Data? {
        var buffer = ByteBuffer(data: blob)
        _ = readSSHString(&buffer)  // "ssh-ed25519"
        guard let pubBuf = readSSHBuffer(&buffer) else { return nil }
        return pubBuf.getData(at: pubBuf.readerIndex, length: pubBuf.readableBytes)
    }
}

// MARK: - Raw-bytes Digest workaround

/// A raw 32-byte digest that conforms to swift-crypto's `Digest`
/// protocol just enough to be passed into
/// `P256.Signing.PrivateKey.signature(for:)`.
///
/// swift-crypto's public ECDSA API only takes concrete digest types
/// (`SHA256Digest` etc.), which have no `init(rawBytes:)` exposed —
/// you can only obtain them by running the hash function. For GPG
/// agent forwarding the digest arrives precomputed via `SETHASH`, so
/// we need a way to wrap arbitrary 32 bytes in a `Digest`-conforming
/// type. Conforming our own type to `Digest` satisfies the protocol
/// at the type level; `signature(for:)` ultimately reads the bytes via
/// `withUnsafeBytes`, which is the only thing that actually matters.
private struct Hash32: Digest {
    static var byteCount: Int { 32 }
    private let storage: [UInt8]

    init(bytes: Data) {
        precondition(bytes.count == 32)
        self.storage = Array(bytes)
    }

    func makeIterator() -> Array<UInt8>.Iterator {
        storage.makeIterator()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try storage.withUnsafeBytes(body)
    }
}
