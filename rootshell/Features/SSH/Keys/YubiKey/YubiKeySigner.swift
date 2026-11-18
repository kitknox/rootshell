//
//  YubiKeySigner.swift
//  rootshell
//
//  Handles signing operations with YubiKey PIV
//  Migrated to yubikit-swift SDK with async/await APIs
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os.log
import YubiKit
import Crypto
import NIOCore

/// Handles signing operations with YubiKey
///
/// Signing operations are serialized to prevent conflicts when multiple tabs
/// attempt to use the YubiKey simultaneously. The YubiKey caches PIN verification
/// for the session, so only the first operation requires PIN entry.
@MainActor
final class YubiKeySigner {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeySigner"
    )

    private let connectionManager: YubiKeyConnectionManager

    /// Shared signer instance for serializing operations across all tabs. The
    /// only instance: a second one would have its own PIN cache.
    static let shared = YubiKeySigner(connectionManager: .shared)

    /// Whether PIN has been verified in the current session
    /// For wired connections: reset when connection is lost
    /// For NFC: PIN is re-verified each tap using cached value
    private var pinVerifiedForSession = false

    /// Cached PIN for NFC operations
    /// NFC connections are transient - YubiKey doesn't cache PIN across taps
    /// We cache it here to avoid prompting user for each operation
    private var cachedPINForSession: String?

    /// The NFC connection the PIN was verified on, if any. The YubiKey holds
    /// that verification only for that connection, so a new tap, even of the
    /// same key, never matches and verifies the cached PIN again.
    private var pinVerifiedNFCConnection: Int?

    /// Serial of the YubiKey the cached PIN and verified flags belong to.
    private var pinStateSerial: UInt32?

    private init(connectionManager: YubiKeyConnectionManager) {
        self.connectionManager = connectionManager

        // Listen for WIRED disconnection to reset PIN state
        // NFC disconnects are expected and handled differently (PIN is cached)
        Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(named: .yubiKeyDidDisconnect) {
                // Extract connection method from notification
                let methodRawValue = notification.userInfo?["method"] as? String
                let method = methodRawValue.flatMap { YubiKeyConnectionMethod(rawValue: $0) }

                // Only reset PIN state for wired disconnects
                // NFC operations handle their own PIN caching
                if method != .nfc {
                    Self.logger.info("Wired YubiKey disconnected - resetting PIN state")
                    self.pinVerifiedForSession = false
                    self.cachedPINForSession = nil
                }
            }
        }
    }

    /// Acquire exclusive access to the YubiKey for signing. The queue lives in
    /// the connection manager so Settings actions wait in it too.
    private func acquireSigningLock(serial: UInt32) async throws {
        guard await connectionManager.beginExclusiveUse(reusingNFCSessionOf: serial) else {
            // Cancelled before its turn, for example by its SSH request timing out.
            throw CancellationError()
        }
    }

    /// Whether the operation queued next is another signing operation for the
    /// YubiKey this NFC session is connected to, which reuses the session and
    /// ends it. Anything else opens its own.
    private var hasQueuedOperations: Bool {
        connectionManager.nextOperationReusesNFCSession
    }

    /// Release the signing lock and allow next queued operation
    private func releaseSigningLock() {
        connectionManager.endExclusiveUse()
    }

    // MARK: - Device Binding

    /// Drop cached PIN state that belongs to another YubiKey. A serial of 0
    /// means none was reported; that identifies no key to hold a PIN for.
    private func scopePINState(to serial: UInt32) throws {
        guard serial != 0 else {
            clearPINState()
            pinStateSerial = nil
            throw YubiKeyError.unverifiedDevice
        }
        guard pinStateSerial != serial else { return }
        clearPINState()
        pinStateSerial = serial
    }

    private func clearPINState() {
        cachedPINForSession = nil
        pinVerifiedForSession = false
        pinVerifiedNFCConnection = nil
    }

    /// Stop if the caller has gone away because its request timed out or was
    /// cancelled, so a result nobody is waiting for doesn't prompt for a PIN
    /// or use the key. Checked on getting the queue, before connecting, before
    /// a PIN is sent, and before each sign, decrypt or key agreement. An NFC
    /// session left open is ended when the queue is released.
    private func checkStillWanted() throws {
        try Task.checkCancellation()
    }

    /// End an NFC session inherited from the previous signature before the
    /// app's PIN prompt, which the system NFC sheet would cover. The tap after
    /// entry opens a new session.
    private func endInheritedNFCSession() async {
        #if os(iOS) && !os(visionOS)
        await connectionManager.closeNFCSessionImmediately()
        pinVerifiedNFCConnection = nil
        #endif
    }

    /// PIV session on the YubiKey the key reference names. Identity and session
    /// come from one captured connection, so a PIN can't reach another key.
    private func verifiedSession(
        serial: UInt32
    ) async throws -> (session: PIVSession, method: YubiKeyConnectionMethod, connectionID: Int) {
        do {
            return try await connectionManager.verifiedPIVSession(serial: serial)
        } catch {
            // A refusal ends the NFC session.
            pinVerifiedNFCConnection = nil
            throw error
        }
    }

    // MARK: - PIV Signing

    /// Sign data using a PIV slot
    func signWithPIV(
        serialNumber: UInt32,
        slot: PIVSlot,
        algorithm: YubiKeyAlgorithm,
        data: Data,
        flags: UInt32
    ) async throws -> ByteBuffer {
        // Serialize operations
        try await acquireSigningLock(serial: serialNumber)
        defer { releaseSigningLock() }
        try checkStillWanted()

        // Surface the hardware-key overlay for this SSH/agent signing op. The
        // overlay only becomes visible if we end up waiting on the key (insert
        // or touch); a present key signs fast enough to never show it. Settings
        // / management ops don't go through the signer, so they never trigger
        // it.
        HardwareKeyActivityCoordinator.shared.beginActivity()
        defer { HardwareKeyActivityCoordinator.shared.finishActivity() }

        // For NFC: collect PIN BEFORE starting NFC session
        let willUseNFC = await connectionManager.willUseNFC()

        // Determine if we need to prompt for PIN
        try scopePINState(to: serialNumber)
        let needsPINPrompt = slot.requiresPIN && cachedPINForSession == nil && !pinVerifiedForSession

        if willUseNFC && needsPINPrompt {
            await endInheritedNFCSession()
            Self.logger.info("NFC mode: collecting PIN before starting NFC session")
            cachedPINForSession = try await connectionManager.requestPIN(for: "YubiKey")
        }

        // Ensure connected
        try checkStillWanted()
        try await connectionManager.connect()

        // Fresh PIV session on the referenced YubiKey; any other key is refused
        // before a PIN is submitted to it.
        let verified = try await verifiedSession(serial: serialNumber)
        let session = verified.session
        let connectionID = verified.connectionID
        let connectionMethod: YubiKeyConnectionMethod? = verified.method
        try checkStillWanted()
        let pivSlot = slot.toYubiKitSlot

        // Verify PIN if required
        if slot.requiresPIN {
            do {
                if connectionMethod == .nfc {
                    // NFC: verify once per NFC session
                    if pinVerifiedNFCConnection != connectionID {
                        if let pin = cachedPINForSession {
                            Self.logger.info("NFC mode: verifying PIN with YubiKey using cached value")
                            try await verifyPINWithValue(session: session, pin: pin)
                            pinVerifiedNFCConnection = connectionID
                        } else {
                            Self.logger.error("NFC mode: no cached PIN available")
                            throw YubiKeyError.pinRequired
                        }
                    } else {
                        Self.logger.info("NFC mode: PIN already verified in this session, skipping")
                    }
                } else if !pinVerifiedForSession {
                    // Wired: verify once, then YubiKey caches
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                    } else {
                        try await verifyPIN(session: session, slot: slot)
                    }
                    pinVerifiedForSession = true
                }
            } catch {
                // Clear cached PIN on verification failure
                if (error as? YubiKeyError)?.isSecurityError == true {
                    Self.logger.warning("PIN verification failed - clearing cached PIN")
                    cachedPINForSession = nil
                    pinVerifiedForSession = false
                    pinVerifiedNFCConnection = nil
                }
                // Close NFC session if needed
                #if os(iOS) && !os(visionOS)
                if connectionMethod == .nfc {
                    await connectionManager.closeNFCSession(withError: "PIN verification failed")
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                } else if let method = connectionMethod {
                    // Wired: restore .connected so the next attempt reuses this
                    // still-open connection instead of opening a second SDK
                    // connection, which fails with "another connection in progress".
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #else
                if let method = connectionMethod {
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #endif
                throw error
            }
        }

        // Update state
        connectionManager.updateState(.signing)

        // Escalate to a prominent "Touch your YubiKey now" prompt if a wired
        // sign blocks past a short grace period — i.e. the slot's touch policy
        // is waiting on a finger. Fast non-touch signs complete first and never
        // show it. NFC keeps the system sheet, so we don't escalate there.
        let touchEscalation: Task<Void, Never>?
        if connectionMethod != .nfc {
            touchEscalation = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                HardwareKeyActivityCoordinator.shared.update(phase: .touchRequired)
            }
        } else {
            touchEscalation = nil
        }
        defer { touchEscalation?.cancel() }

        // Perform signing using new type-specific APIs
        // If signing fails with security error, retry once after re-verifying PIN
        let signature: Data
        do {
            signature = try await performSigningWithRetry(
                session: session,
                slot: slot,
                pivSlot: pivSlot,
                algorithm: algorithm,
                data: data,
                flags: flags,
                connectionMethod: connectionMethod,
                connectionID: connectionID
            )
            Self.logger.info("PIV signing successful for slot \(slot.rawValue)")
        } catch {
            Self.logger.error("PIV signing failed: \(error.localizedDescription)")
            // Handle post-error state
            if let method = connectionMethod {
                #if os(iOS) && !os(visionOS)
                if method == .nfc {
                    await connectionManager.closeNFCSession(withError: "Signing failed")
                    connectionManager.updateState(.disconnected)
                } else {
                    restoreConnectedState(method: method)
                }
                #else
                restoreConnectedState(method: method)
                #endif
            }
            throw error
        }

        // Handle post-signing state
        if let method = connectionMethod {
            #if os(iOS) && !os(visionOS)
            if method == .nfc {
                if hasQueuedOperations {
                    Self.logger.info("NFC signing complete, keeping session open for the next signing operation")
                    restoreConnectedState(method: method)
                } else {
                    Self.logger.info("NFC signing complete, no more operations - closing session")
                    await connectionManager.closeNFCSessionImmediately()
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                }
            } else {
                restoreConnectedState(method: method)
            }
            #else
            restoreConnectedState(method: method)
            #endif
        }

        // Format signature for SSH
        return formatSSHSignature(signature, algorithm: algorithm, flags: flags)
    }

    // MARK: - PIV Prehashed Signing (for GPG agent forwarding)

    /// Sign a precomputed digest using a PIV slot. Unlike
    /// ``signWithPIV(slot:algorithm:data:flags:)``, this does not wrap
    /// the output in SSH wire format and does not hash the input —
    /// the digest must already be the SHA-1/224/256/384/512 output the
    /// remote `gpg-agent` set via `SETHASH`. Returns the raw signature
    /// bytes: 64 bytes (r||s) for Ed25519, an ASN.1 DER `SEQUENCE
    /// { r, s }` for ECDSA, and the modulus-width RSA signature for
    /// RSA.
    ///
    /// Same PIN / NFC / connection plumbing as ``signWithPIV`` —
    /// duplicated rather than refactored to avoid risk to the
    /// established SSH-agent path. If a bug surfaces in one, fix it
    /// in both.
    func signWithPIVPrehashed(
        serialNumber: UInt32,
        slot: PIVSlot,
        algorithm: YubiKeyAlgorithm,
        digest: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) async throws -> Data {
        try await acquireSigningLock(serial: serialNumber)
        defer { releaseSigningLock() }
        try checkStillWanted()

        let willUseNFC = await connectionManager.willUseNFC()
        try scopePINState(to: serialNumber)
        let needsPINPrompt = slot.requiresPIN && cachedPINForSession == nil && !pinVerifiedForSession
        if willUseNFC && needsPINPrompt {
            await endInheritedNFCSession()
            cachedPINForSession = try await connectionManager.requestPIN(for: "YubiKey")
        }

        try checkStillWanted()
        try await connectionManager.connect()

        let verified = try await verifiedSession(serial: serialNumber)
        let session = verified.session
        let connectionID = verified.connectionID
        let connectionMethod: YubiKeyConnectionMethod? = verified.method
        try checkStillWanted()
        let pivSlot = slot.toYubiKitSlot

        if slot.requiresPIN {
            do {
                if connectionMethod == .nfc {
                    if pinVerifiedNFCConnection != connectionID {
                        if let pin = cachedPINForSession {
                            try await verifyPINWithValue(session: session, pin: pin)
                            pinVerifiedNFCConnection = connectionID
                        } else {
                            throw YubiKeyError.pinRequired
                        }
                    }
                } else if !pinVerifiedForSession {
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                    } else {
                        try await verifyPIN(session: session, slot: slot)
                    }
                    pinVerifiedForSession = true
                }
            } catch {
                if (error as? YubiKeyError)?.isSecurityError == true {
                    cachedPINForSession = nil
                    pinVerifiedForSession = false
                    pinVerifiedNFCConnection = nil
                }
                #if os(iOS) && !os(visionOS)
                if connectionMethod == .nfc {
                    await connectionManager.closeNFCSession(withError: "PIN verification failed")
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                } else if let method = connectionMethod {
                    // Wired: restore .connected so the next attempt reuses this
                    // still-open connection instead of opening a second SDK
                    // connection, which fails with "another connection in progress".
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #else
                if let method = connectionMethod {
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #endif
                throw error
            }
        }

        connectionManager.updateState(.signing)

        let signature: Data
        do {
            signature = try await performPrehashedSigningWithRetry(
                session: session,
                slot: slot,
                pivSlot: pivSlot,
                algorithm: algorithm,
                digest: digest,
                hashAlgorithm: hashAlgorithm,
                connectionMethod: connectionMethod,
                connectionID: connectionID
            )
        } catch {
            if let method = connectionMethod {
                #if os(iOS) && !os(visionOS)
                if method == .nfc {
                    await connectionManager.closeNFCSession(withError: "Signing failed")
                    connectionManager.updateState(.disconnected)
                } else {
                    restoreConnectedState(method: method)
                }
                #else
                restoreConnectedState(method: method)
                #endif
            }
            throw error
        }

        if let method = connectionMethod {
            #if os(iOS) && !os(visionOS)
            if method == .nfc {
                if hasQueuedOperations {
                    restoreConnectedState(method: method)
                } else {
                    await connectionManager.closeNFCSessionImmediately()
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                }
            } else {
                restoreConnectedState(method: method)
            }
            #else
            restoreConnectedState(method: method)
            #endif
        }

        return signature
    }

    // MARK: - PIV Decrypt (for GPG agent forwarding)

    /// Run the YubiKey's PIV decrypt instruction against an RSA slot.
    /// Mirrors ``signWithPIVPrehashed`` for connection / PIN / NFC
    /// plumbing — the only difference is the YubiKit primitive at the
    /// core. The card performs `c^d mod n` internally and strips
    /// PKCS#1 v1.5 EME padding; the returned bytes are the OpenPGP
    /// session-key wrapping that gpg consumes on the client side.
    func decryptWithPIV(
        serialNumber: UInt32,
        slot: PIVSlot,
        algorithm: YubiKeyAlgorithm,
        ciphertext: Data
    ) async throws -> Data {
        try await acquireSigningLock(serial: serialNumber)
        defer { releaseSigningLock() }
        try checkStillWanted()

        let willUseNFC = await connectionManager.willUseNFC()
        try scopePINState(to: serialNumber)
        let needsPINPrompt = slot.requiresPIN && cachedPINForSession == nil && !pinVerifiedForSession
        if willUseNFC && needsPINPrompt {
            await endInheritedNFCSession()
            cachedPINForSession = try await connectionManager.requestPIN(for: "YubiKey")
        }

        try checkStillWanted()
        try await connectionManager.connect()

        let verified = try await verifiedSession(serial: serialNumber)
        let session = verified.session
        let connectionID = verified.connectionID
        let connectionMethod: YubiKeyConnectionMethod? = verified.method
        try checkStillWanted()
        let pivSlot = slot.toYubiKitSlot

        if slot.requiresPIN {
            do {
                if connectionMethod == .nfc {
                    if pinVerifiedNFCConnection != connectionID {
                        if let pin = cachedPINForSession {
                            try await verifyPINWithValue(session: session, pin: pin)
                            pinVerifiedNFCConnection = connectionID
                        } else {
                            throw YubiKeyError.pinRequired
                        }
                    }
                } else if !pinVerifiedForSession {
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                    } else {
                        try await verifyPIN(session: session, slot: slot)
                    }
                    pinVerifiedForSession = true
                }
            } catch {
                if (error as? YubiKeyError)?.isSecurityError == true {
                    cachedPINForSession = nil
                    pinVerifiedForSession = false
                    pinVerifiedNFCConnection = nil
                }
                #if os(iOS) && !os(visionOS)
                if connectionMethod == .nfc {
                    await connectionManager.closeNFCSession(withError: "PIN verification failed")
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                } else if let method = connectionMethod {
                    // Wired: restore .connected so the next attempt reuses this
                    // still-open connection instead of opening a second SDK
                    // connection, which fails with "another connection in progress".
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #else
                if let method = connectionMethod {
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #endif
                throw error
            }
        }

        connectionManager.updateState(.signing)

        let plaintext: Data
        do {
            try checkStillWanted()
            switch algorithm {
            case .rsa2048, .rsa4096:
                plaintext = try await session.decrypt(
                    ciphertext,
                    in: pivSlot,
                    using: .pkcs1v15
                )
            case .ecdsaP256, .ecdsaP384, .ed25519, .mldsa44, .mldsa65, .mldsa87:
                throw YubiKeyError.signingFailed("Slot algorithm \(algorithm.rawValue) doesn't support PIV decrypt")
            }
        } catch {
            if let method = connectionMethod {
                #if os(iOS) && !os(visionOS)
                if method == .nfc {
                    await connectionManager.closeNFCSession(withError: "Decrypt failed")
                    connectionManager.updateState(.disconnected)
                } else {
                    restoreConnectedState(method: method)
                }
                #else
                restoreConnectedState(method: method)
                #endif
            }
            throw error
        }

        if let method = connectionMethod {
            #if os(iOS) && !os(visionOS)
            if method == .nfc {
                if hasQueuedOperations {
                    restoreConnectedState(method: method)
                } else {
                    await connectionManager.closeNFCSessionImmediately()
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                }
            } else {
                restoreConnectedState(method: method)
            }
            #else
            restoreConnectedState(method: method)
            #endif
        }

        return plaintext
    }

    /// Run the YubiKey's PIV ECDH (DERIVE) instruction against an EC
    /// slot. The card computes the shared secret `d·E` and returns
    /// its X coordinate. Caller applies the OpenPGP ECDH KDF + AES
    /// Key Unwrap to recover the session key.
    func deriveSharedSecretWithPIV(
        serialNumber: UInt32,
        slot: PIVSlot,
        algorithm: YubiKeyAlgorithm,
        peerPublicKey: Data
    ) async throws -> Data {
        try await acquireSigningLock(serial: serialNumber)
        defer { releaseSigningLock() }
        try checkStillWanted()

        let willUseNFC = await connectionManager.willUseNFC()
        try scopePINState(to: serialNumber)
        let needsPINPrompt = slot.requiresPIN && cachedPINForSession == nil && !pinVerifiedForSession
        if willUseNFC && needsPINPrompt {
            await endInheritedNFCSession()
            cachedPINForSession = try await connectionManager.requestPIN(for: "YubiKey")
        }

        try checkStillWanted()
        try await connectionManager.connect()

        let verified = try await verifiedSession(serial: serialNumber)
        let session = verified.session
        let connectionID = verified.connectionID
        let connectionMethod: YubiKeyConnectionMethod? = verified.method
        try checkStillWanted()
        let pivSlot = slot.toYubiKitSlot

        if slot.requiresPIN {
            do {
                if connectionMethod == .nfc {
                    if pinVerifiedNFCConnection != connectionID {
                        if let pin = cachedPINForSession {
                            try await verifyPINWithValue(session: session, pin: pin)
                            pinVerifiedNFCConnection = connectionID
                        } else {
                            throw YubiKeyError.pinRequired
                        }
                    }
                } else if !pinVerifiedForSession {
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                    } else {
                        try await verifyPIN(session: session, slot: slot)
                    }
                    pinVerifiedForSession = true
                }
            } catch {
                if (error as? YubiKeyError)?.isSecurityError == true {
                    cachedPINForSession = nil
                    pinVerifiedForSession = false
                    pinVerifiedNFCConnection = nil
                }
                #if os(iOS) && !os(visionOS)
                if connectionMethod == .nfc {
                    await connectionManager.closeNFCSession(withError: "PIN verification failed")
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                } else if let method = connectionMethod {
                    // Wired: restore .connected so the next attempt reuses this
                    // still-open connection instead of opening a second SDK
                    // connection, which fails with "another connection in progress".
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #else
                if let method = connectionMethod {
                    restoreConnectedState(method: method)
                } else {
                    connectionManager.disconnect()
                }
                #endif
                throw error
            }
        }

        connectionManager.updateState(.signing)

        let shared: Data
        do {
            try checkStillWanted()
            switch algorithm {
            case .ecdsaP256:
                guard let pub = EC.PublicKey(x963: peerPublicKey, curve: .secp256r1) else {
                    throw YubiKeyError.signingFailed("Failed to parse P-256 peer public key")
                }
                shared = try await session.deriveSharedSecret(in: pivSlot, with: pub)
            case .ecdsaP384:
                guard let pub = EC.PublicKey(x963: peerPublicKey, curve: .secp384r1) else {
                    throw YubiKeyError.signingFailed("Failed to parse P-384 peer public key")
                }
                shared = try await session.deriveSharedSecret(in: pivSlot, with: pub)
            case .rsa2048, .rsa4096, .ed25519, .mldsa44, .mldsa65, .mldsa87:
                throw YubiKeyError.signingFailed("ECDH not applicable for \(algorithm.rawValue)")
            }
        } catch {
            if let method = connectionMethod {
                #if os(iOS) && !os(visionOS)
                if method == .nfc {
                    await connectionManager.closeNFCSession(withError: "ECDH failed")
                    connectionManager.updateState(.disconnected)
                } else {
                    restoreConnectedState(method: method)
                }
                #else
                restoreConnectedState(method: method)
                #endif
            }
            throw error
        }

        if let method = connectionMethod {
            #if os(iOS) && !os(visionOS)
            if method == .nfc {
                if hasQueuedOperations {
                    restoreConnectedState(method: method)
                } else {
                    await connectionManager.closeNFCSessionImmediately()
                    connectionManager.updateState(.disconnected)
                    pinVerifiedNFCConnection = nil
                }
            } else {
                restoreConnectedState(method: method)
            }
            #else
            restoreConnectedState(method: method)
            #endif
        }

        return shared
    }

    private func performPrehashedSigningWithRetry(
        session: PIVSession,
        slot: PIVSlot,
        pivSlot: PIV.Slot,
        algorithm: YubiKeyAlgorithm,
        digest: Data,
        hashAlgorithm: GPGHashAlgorithm,
        connectionMethod: YubiKeyConnectionMethod?,
        connectionID: Int
    ) async throws -> Data {
        do {
            return try await performPrehashedSigning(
                session: session, slot: pivSlot, algorithm: algorithm,
                digest: digest, hashAlgorithm: hashAlgorithm
            )
        } catch let error as YubiKeyError where error.isSecurityError {
            pinVerifiedForSession = false
            pinVerifiedNFCConnection = nil
            if slot.requiresPIN {
                if connectionMethod == .nfc {
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                        pinVerifiedNFCConnection = connectionID
                    } else {
                        throw YubiKeyError.pinRequired
                    }
                } else {
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                    } else {
                        try await verifyPIN(session: session, slot: slot)
                    }
                    pinVerifiedForSession = true
                }
            }
            return try await performPrehashedSigning(
                session: session, slot: pivSlot, algorithm: algorithm,
                digest: digest, hashAlgorithm: hashAlgorithm
            )
        }
    }

    /// Dispatch a precomputed-digest sign through the right YubiKit
    /// primitive per key algorithm:
    /// * RSA: pre-build the PKCS#1 v1.5 EMSA block (`0x00 0x01 PS 0x00
    ///   DigestInfo digest`) sized to the modulus byte length, then
    ///   feed it through ``.raw`` so the YubiKey performs only the
    ///   modular exponentiation. This is what we'd get if we asked
    ///   YubiKit's `.pkcs1v15` path to skip its internal hashing —
    ///   but that's not a configurable option, so we do the encoding
    ///   ourselves.
    /// * ECDSA: ``.prehashed(...)`` is YubiKit's native
    ///   precomputed-digest path. The returned bytes are the DER
    ///   `SEQUENCE { r, s }` — gpg expects raw r/s pairs in the
    ///   `sig-val` S-expression, so the caller parses the DER.
    /// * Ed25519: pass the digest as the "message"; Ed25519 hashes it
    ///   internally with SHA-512 as part of the EdDSA spec, exactly
    ///   what gpg-agent does.
    private func performPrehashedSigning(
        session: PIVSession,
        slot: PIV.Slot,
        algorithm: YubiKeyAlgorithm,
        digest: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) async throws -> Data {
        // Covers the first attempt and the retry.
        try checkStillWanted()

        // Build any pre-padded data outside the typed-throws block so
        // the catch only sees PIVSessionError (the only error
        // YubiKeyError.from can downcast).
        let prepared: Data
        let pivKeyType: PIV.KeyType
        let pivAlgorithm: PIVAlgorithmDispatch
        switch algorithm {
        case .rsa2048, .rsa4096:
            let keysize: RSA.KeySize = (algorithm == .rsa2048) ? .bits2048 : .bits4096
            do {
                prepared = try Self.buildPKCS1v15Block(
                    digest: digest,
                    hashAlgorithm: hashAlgorithm,
                    modulusByteLength: keysize.byteCount
                )
            } catch {
                throw YubiKeyError.signingFailed(error.localizedDescription)
            }
            pivKeyType = .rsa(keysize)
            pivAlgorithm = .rsaRaw
        case .ecdsaP256:
            prepared = digest
            pivKeyType = .ec(.secp256r1)
            pivAlgorithm = .ecPrehashedSHA256
        case .ecdsaP384:
            prepared = digest
            pivKeyType = .ec(.secp384r1)
            pivAlgorithm = .ecPrehashedSHA384
        case .ed25519:
            prepared = digest
            pivKeyType = .ed25519
            pivAlgorithm = .ed25519
        case .mldsa44, .mldsa65, .mldsa87:
            // Pure ML-DSA signs the message itself; there is no prehashed form.
            throw YubiKeyError.unsupportedFeature("ML-DSA keys cannot sign OpenPGP digests")
        }

        do {
            switch pivAlgorithm {
            case .rsaRaw:
                guard case .rsa(let keysize) = pivKeyType else { fatalError("dispatch mismatch") }
                return try await session.sign(prepared, in: slot, keyType: .rsa(keysize), using: .raw)
            case .ecPrehashedSHA256:
                return try await session.sign(prepared, in: slot, keyType: .ec(.secp256r1), using: .prehashed(.sha256))
            case .ecPrehashedSHA384:
                return try await session.sign(prepared, in: slot, keyType: .ec(.secp384r1), using: .prehashed(.sha384))
            case .ed25519:
                return try await session.sign(prepared, in: slot, keyType: .ed25519)
            }
        } catch {
            throw YubiKeyError.from(error)
        }
    }

    /// Compact dispatch tag for ``performPrehashedSigning``. The set
    /// of YubiKit primitives we route to is small enough that the
    /// switch-on-enum is clearer than nested key-type checks.
    private enum PIVAlgorithmDispatch {
        case rsaRaw
        case ecPrehashedSHA256
        case ecPrehashedSHA384
        case ed25519
    }

    /// Build the EMSA-PKCS1-v1_5 encoded message for a signing op:
    ///   `0x00 || 0x01 || PS(0xFF, ≥8 bytes) || 0x00 || T`
    /// where `T` is the DER DigestInfo for the requested hash followed
    /// by the digest bytes. Throws if there isn't room for a valid
    /// minimum-length PS (i.e., modulus too small for the hash).
    static func buildPKCS1v15Block(
        digest: Data,
        hashAlgorithm: GPGHashAlgorithm,
        modulusByteLength: Int
    ) throws -> Data {
        let digestInfoPrefix: [UInt8]
        let expectedLen: Int
        switch hashAlgorithm {
        case .sha1:
            digestInfoPrefix = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2B, 0x0E, 0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14]
            expectedLen = 20
        case .sha224:
            digestInfoPrefix = [0x30, 0x2D, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x04, 0x05, 0x00, 0x04, 0x1C]
            expectedLen = 28
        case .sha256:
            digestInfoPrefix = [0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20]
            expectedLen = 32
        case .sha384:
            digestInfoPrefix = [0x30, 0x41, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30]
            expectedLen = 48
        case .sha512:
            digestInfoPrefix = [0x30, 0x51, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40]
            expectedLen = 64
        case .unknown(let id):
            throw NSError(domain: "YubiKeySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported PKCS#1 hash id \(id)"])
        }
        guard digest.count == expectedLen else {
            throw NSError(domain: "YubiKeySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: "PKCS#1 digest length mismatch"])
        }

        let t = digestInfoPrefix + Array(digest)
        // PS length = modulusByteLength - 3 - t.count; must be ≥ 8.
        let psLength = modulusByteLength - 3 - t.count
        guard psLength >= 8 else {
            throw NSError(domain: "YubiKeySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: "RSA modulus too small for PKCS#1 v1.5 padding with this hash"])
        }

        var em = Data()
        em.append(0x00)
        em.append(0x01)
        em.append(contentsOf: Array(repeating: UInt8(0xFF), count: psLength))
        em.append(0x00)
        em.append(contentsOf: t)
        return em
    }

    /// Perform signing with automatic retry on security errors
    ///
    /// PIV sessions are transient - each session requires its own PIN verification.
    /// If signing fails with 0x6982 (security condition not satisfied), this method
    /// will re-verify PIN and retry once.
    private func performSigningWithRetry(
        session: PIVSession,
        slot: PIVSlot,
        pivSlot: PIV.Slot,
        algorithm: YubiKeyAlgorithm,
        data: Data,
        flags: UInt32,
        connectionMethod: YubiKeyConnectionMethod?,
        connectionID: Int
    ) async throws -> Data {
        do {
            return try await performSigning(session: session, slot: pivSlot, algorithm: algorithm, data: data, flags: flags)
        } catch let error as YubiKeyError where error.isSecurityError {
            // Security error on first attempt - PIN verification may have expired
            // This happens when PIV session is recreated (new SSH connection)
            Self.logger.info("Signing failed with security error - re-verifying PIN and retrying")

            // Reset PIN state
            pinVerifiedForSession = false
            pinVerifiedNFCConnection = nil

            // Re-verify PIN
            if slot.requiresPIN {
                if connectionMethod == .nfc {
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                        pinVerifiedNFCConnection = connectionID
                    } else {
                        Self.logger.error("NFC mode: no cached PIN available for retry")
                        throw YubiKeyError.pinRequired
                    }
                } else {
                    // Wired: use cached PIN or prompt
                    if let pin = cachedPINForSession {
                        try await verifyPINWithValue(session: session, pin: pin)
                    } else {
                        try await verifyPIN(session: session, slot: slot)
                    }
                    pinVerifiedForSession = true
                }
            }

            // Retry signing once
            Self.logger.info("Retrying signing after PIN re-verification")
            return try await performSigning(session: session, slot: pivSlot, algorithm: algorithm, data: data, flags: flags)
        }
    }

    /// Perform the actual signing operation using new SDK APIs
    private func performSigning(
        session: PIVSession,
        slot: PIV.Slot,
        algorithm: YubiKeyAlgorithm,
        data: Data,
        flags: UInt32
    ) async throws -> Data {
        // Covers the first attempt and the retry. Kept outside the typed-throws block.
        try checkStillWanted()
        do {
            switch algorithm {
            case .rsa2048:
                let hashAlg: PIV.HashAlgorithm = (flags & 4 != 0) ? .sha512 : .sha256
                return try await session.sign(data, in: slot, keyType: .rsa(.bits2048), using: .pkcs1v15(hashAlg))
            case .rsa4096:
                let hashAlg: PIV.HashAlgorithm = (flags & 4 != 0) ? .sha512 : .sha256
                return try await session.sign(data, in: slot, keyType: .rsa(.bits4096), using: .pkcs1v15(hashAlg))
            case .ecdsaP256:
                return try await session.sign(data, in: slot, keyType: .ec(.secp256r1), using: .hash(.sha256))
            case .ecdsaP384:
                return try await session.sign(data, in: slot, keyType: .ec(.secp384r1), using: .hash(.sha384))
            case .ed25519:
                return try await session.sign(data, in: slot, keyType: .ed25519)
            // Pure ML-DSA with an empty context, as SSH specifies.
            case .mldsa44:
                return try await session.sign(data, in: slot, keyType: .mlDSA(.mlDSA44))
            case .mldsa65:
                return try await session.sign(data, in: slot, keyType: .mlDSA(.mlDSA65))
            case .mldsa87:
                return try await session.sign(data, in: slot, keyType: .mlDSA(.mlDSA87))
            }
        } catch {
            // SDK uses typed throws(PIVSessionError)
            throw YubiKeyError.from(error)
        }
    }

    private func restoreConnectedState(method: YubiKeyConnectionMethod) {
        connectionManager.restoreConnectedState(for: method)
    }

    // MARK: - PIN Handling

    private func verifyPIN(session: PIVSession, slot: PIVSlot) async throws {
        connectionManager.updateState(.authenticating)

        let pin = try await connectionManager.requestPIN(for: slot.displayName)
        try checkStillWanted()

        // Cache PIN for subsequent operations
        cachedPINForSession = pin

        try await verifyPINWithValue(session: session, pin: pin)
    }

    private func verifyPINWithValue(session: PIVSession, pin: String) async throws {
        // Last point before the PIN leaves the app.
        try checkStillWanted()
        connectionManager.updateState(.authenticating)

        // PIV PINs are 1-8 bytes; the SDK traps on longer values. Clear the
        // cache so the next attempt re-prompts instead of re-failing.
        guard (1...8).contains(pin.utf8.count) else {
            cachedPINForSession = nil
            pinVerifiedForSession = false
            pinVerifiedNFCConnection = nil
            throw YubiKeyError.yubiKitError("PIN must be 6-8 digits")
        }

        do {
            let result = try await session.verifyPin(pin)
            switch result {
            case .success:
                return
            case .fail(let retries):
                throw YubiKeyError.pinIncorrect(attemptsRemaining: retries)
            case .pinLocked:
                throw YubiKeyError.pinBlocked
            }
        } catch let error as PIVSessionError {
            throw YubiKeyError.from(error)
        }
    }

    // MARK: - PIN Management

    /// Change the YubiKey PIV PIN
    func changePIN(oldPIN: String, newPIN: String, expectedSerial: UInt32) async throws {
        // Queued with signing: both drive the same connection and PIN cache, and
        // a sign in flight must not have its connection taken or PIN state reset.
        // Like other Settings actions, a sign still waiting for a key gives way.
        guard await connectionManager.beginExclusiveUse(preemptingPendingConnect: true) else {
            throw CancellationError()
        }
        defer { releaseSigningLock() }
        try checkStillWanted()

        Self.logger.info("Initiating PIN change operation")

        // Connect to YubiKey
        try await connectionManager.connect()

        // The old PIN must only go to the YubiKey the user was shown.
        let (session, connectionMethod, _) = try await connectionManager.verifiedPIVSession(serial: expectedSerial)

        do {
            try await session.changePin(from: oldPIN, to: newPIN)

            Self.logger.info("PIN changed successfully")

            // Clear cached PIN since it changed
            cachedPINForSession = nil
            pinVerifiedForSession = false
            pinVerifiedNFCConnection = nil

            // Handle NFC session closure with success message
            #if os(iOS) && !os(visionOS)
            if connectionMethod == .nfc {
                await connectionManager.closeNFCSession(withMessage: "PIN changed successfully")
                connectionManager.updateState(.disconnected)
            }
            #endif

        } catch {
            // SDK uses typed throws(PIVSessionError)
            Self.logger.error("PIN change failed: \(error)")

            // Clear cached PIN on failure
            cachedPINForSession = nil
            pinVerifiedForSession = false
            pinVerifiedNFCConnection = nil

            // Handle NFC session closure with error
            #if os(iOS) && !os(visionOS)
            if connectionMethod == .nfc {
                await connectionManager.closeNFCSession(withError: "PIN change failed")
                connectionManager.updateState(.disconnected)
            }
            #endif
            throw YubiKeyError.from(error)
        }
    }

    // MARK: - Signature Formatting

    private func formatSSHSignature(
        _ rawSignature: Data,
        algorithm: YubiKeyAlgorithm,
        flags: UInt32
    ) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)

        // Determine algorithm name
        let algorithmName: String
        switch algorithm {
        case .rsa2048, .rsa4096:
            algorithmName = (flags & 4 != 0) ? "rsa-sha2-512" : "rsa-sha2-256"
        case .ecdsaP256:
            algorithmName = "ecdsa-sha2-nistp256"
        case .ecdsaP384:
            algorithmName = "ecdsa-sha2-nistp384"
        case .ed25519:
            algorithmName = "ssh-ed25519"
        case .mldsa44, .mldsa65, .mldsa87:
            algorithmName = algorithm.sshKeyTypeString
        }

        // Write algorithm name
        writeSSHStringToBuffer(&buffer, algorithmName)

        // Write signature blob
        switch algorithm {
        case .ecdsaP256, .ecdsaP384:
            // ECDSA signatures need to be converted from DER to SSH format
            let sshSignature = convertECDSASignatureToSSH(rawSignature)
            writeSSHBufferToBuffer(&buffer, sshSignature)
        default:
            writeSSHBufferToBuffer(&buffer, rawSignature)
        }

        return buffer
    }

    private func convertECDSASignatureToSSH(_ derSignature: Data) -> Data {
        // ECDSA DER signature: SEQUENCE { INTEGER r, INTEGER s }
        // SSH format: mpint r + mpint s

        guard derSignature.count > 6,
              derSignature[0] == 0x30 else {
            return derSignature
        }

        var index = 2  // Skip SEQUENCE tag and length

        // Read r
        guard derSignature[index] == 0x02 else { return derSignature }
        index += 1
        let rLength = Int(derSignature[index])
        index += 1
        let r = derSignature.subdata(in: index..<index+rLength)
        index += rLength

        // Read s
        guard derSignature[index] == 0x02 else { return derSignature }
        index += 1
        let sLength = Int(derSignature[index])
        index += 1
        let s = derSignature.subdata(in: index..<index+sLength)

        // Build SSH format
        var sshSignature = Data()
        writeSSHMPInt(&sshSignature, r)
        writeSSHMPInt(&sshSignature, s)

        return sshSignature
    }

    // MARK: - Wire Format Helpers (ByteBuffer)

    private func writeSSHStringToBuffer(_ buffer: inout ByteBuffer, _ string: String) {
        let data = string.data(using: .utf8) ?? Data()
        buffer.writeInteger(UInt32(data.count))
        buffer.writeBytes(data)
    }

    private func writeSSHBufferToBuffer(_ buffer: inout ByteBuffer, _ data: Data) {
        buffer.writeInteger(UInt32(data.count))
        buffer.writeBytes(data)
    }

    // MARK: - Wire Format Helpers (Data - for ECDSA conversion)

    private func writeSSHMPInt(_ buffer: inout Data, _ data: Data) {
        var bytes = [UInt8](data)

        // Remove leading zeros
        while bytes.count > 1 && bytes[0] == 0 {
            bytes.removeFirst()
        }

        // Add leading zero if high bit is set
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }

        writeSSHBuffer(&buffer, Data(bytes))
    }

    private func writeSSHBuffer(_ buffer: inout Data, _ data: Data) {
        var length = UInt32(data.count).bigEndian
        buffer.append(Data(bytes: &length, count: 4))
        buffer.append(data)
    }
}
