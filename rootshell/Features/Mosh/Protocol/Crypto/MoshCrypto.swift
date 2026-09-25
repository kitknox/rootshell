//
//  MoshCrypto.swift
//  rootshell
//
//  AES-128-OCB encryption for mosh protocol
//
//  This implementation uses:
//  - CommonCrypto for hardware-accelerated AES block operations
//  - CryptoSwift's public OCB worker API for mode logic and authentication
//
//  The hybrid approach gives ~100x faster AES operations (hardware)
//  while avoiding reimplementing the complex OCB authenticated encryption.
//
//  Clean-room implementation from IETF specifications:
//  - RFC 7253: The OCB Authenticated-Encryption Algorithm
//  - Mosh protocol documentation
//

import Foundation

/// Mosh crypto session for encrypting/decrypting packets
///
/// Uses AES-128-OCB (Offset Codebook Mode) with:
/// - 128-bit (16-byte) key
/// - 96-bit (12-byte) nonce
/// - 128-bit (16-byte) authentication tag
///
/// Performance optimizations:
/// - Hardware AES via CommonCrypto (Apple Silicon crypto instructions)
/// - Cached AES(K, 0^128), the expensive key-dependent OCB initialization step
///
/// Note: @MainActor instead of actor to avoid context switch overhead.
/// Only called from MoshTransport which is @MainActor.
@MainActor
final class MoshCryptoSession {

    /// Nonce generator for outgoing packets
    private let nonceGenerator: MoshNonceGenerator

    /// Expected sequence number for incoming packets
    private var expectedIncomingSequence: UInt64 = 0

    /// Direction of outgoing messages
    private let outgoingDirection: MoshNonce.Direction

    // MARK: - Cached Crypto State (computed once per session)

    /// Hardware-accelerated AES block encrypt function
    private let aesEncryptBlock: (ArraySlice<UInt8>) -> [UInt8]?

    /// Hardware-accelerated AES block decrypt function
    private let aesDecryptBlock: (ArraySlice<UInt8>) -> [UInt8]?

    // MARK: - Initialization

    /// Creates a new crypto session with the given key
    /// - Parameters:
    ///   - key: The parsed mosh session key
    ///   - isClient: true if this is the client side (sends TO_SERVER)
    init(key: MoshBase64Key, isClient: Bool) {
        self.outgoingDirection = isClient ? .toServer : .toClient
        self.nonceGenerator = MoshNonceGenerator(direction: outgoingDirection)

        // Initialize hardware AES block functions (computed once)
        self.aesEncryptBlock = HardwareAES.blockEncryptor(key: key.bytes)
        self.aesDecryptBlock = HardwareAES.blockDecryptor(key: key.bytes)
    }

    /// Creates a crypto session for resuming with saved state
    /// - Parameters:
    ///   - key: The parsed mosh session key
    ///   - isClient: true if this is the client side (sends TO_SERVER)
    ///   - outgoingSequence: Starting sequence for outgoing packets
    ///   - expectedIncoming: Expected sequence for incoming packets
    init(key: MoshBase64Key, isClient: Bool, outgoingSequence: UInt64, expectedIncoming: UInt64) {
        self.outgoingDirection = isClient ? .toServer : .toClient
        self.nonceGenerator = MoshNonceGenerator(direction: outgoingDirection, startingSequence: outgoingSequence)
        self.expectedIncomingSequence = expectedIncoming

        // Initialize hardware AES block functions (computed once)
        self.aesEncryptBlock = HardwareAES.blockEncryptor(key: key.bytes)
        self.aesDecryptBlock = HardwareAES.blockDecryptor(key: key.bytes)
    }

    // MARK: - Encryption

    /// Encrypts a message for transmission
    /// - Parameter plaintext: The data to encrypt (timestamps + payload)
    /// - Returns: Encrypted packet (8-byte nonce + ciphertext + 16-byte tag)
    /// - Throws: MoshError.encryptionFailed if encryption fails
    func encrypt(_ plaintext: Data) throws -> Data {
        // Get next nonce
        let nonce = nonceGenerator.next()

        do {
            let ciphertextWithTag = try MoshOCBCryptor.encrypt(
                Array(plaintext),
                nonce: nonce.bytes,
                encryptBlock: aesEncryptBlock
            )

            // Build packet: nonce (8 bytes) + ciphertext + tag
            var packet = Data()
            packet.append(nonce.wireBytes)
            packet.append(contentsOf: ciphertextWithTag)

            return packet

        } catch {
            throw MoshError.encryptionFailed(reason: error.localizedDescription)
        }
    }

    /// Encrypts a message with specific nonce (for testing/special cases)
    /// - Parameters:
    ///   - plaintext: The data to encrypt
    ///   - nonce: The specific nonce to use
    /// - Returns: Encrypted packet
    func encrypt(_ plaintext: Data, withNonce nonce: MoshNonce) throws -> Data {
        do {
            let ciphertextWithTag = try MoshOCBCryptor.encrypt(
                Array(plaintext),
                nonce: nonce.bytes,
                encryptBlock: aesEncryptBlock
            )

            var packet = Data()
            packet.append(nonce.wireBytes)
            packet.append(contentsOf: ciphertextWithTag)

            return packet

        } catch {
            throw MoshError.encryptionFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Decryption

    /// Decrypts a received packet
    /// - Parameter packet: The received packet (8-byte nonce + ciphertext + tag)
    /// - Returns: The decrypted plaintext (timestamps + payload)
    /// - Throws: MoshError.decryptionFailed if decryption or authentication fails
    func decrypt(_ packet: Data) throws -> (plaintext: Data, nonce: MoshNonce) {
        // Minimum packet size: 8 (nonce) + 16 (tag) = 24 bytes
        guard packet.count >= 24 else {
            throw MoshError.decryptionFailed(
                reason: "Packet too short: \(packet.count) bytes"
            )
        }

        // Extract nonce (first 8 bytes)
        let nonceData = packet.prefix(8)
        let nonce = try MoshNonce(wireBytes: Data(nonceData))

        // Validate nonce sequence (allow some reordering)
        guard nonce.isValidAfter(expected: expectedIncomingSequence) else {
            throw MoshError.nonceSequenceError(
                expected: expectedIncomingSequence,
                received: nonce.sequenceNumber
            )
        }

        // Extract ciphertext + tag (everything after nonce)
        let ciphertextWithTag = Array(packet.suffix(from: 8))

        do {
            let plaintext = try MoshOCBCryptor.decrypt(
                ciphertextWithTag,
                nonce: nonce.bytes,
                encryptBlock: aesEncryptBlock,
                decryptBlock: aesDecryptBlock
            )

            // Update expected sequence
            if nonce.sequenceNumber >= expectedIncomingSequence {
                expectedIncomingSequence = nonce.sequenceNumber + 1
            }

            return (plaintext: Data(plaintext), nonce: nonce)

        } catch {
            throw MoshError.decryptionFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - State Management

    /// Resets the crypto session state (for reconnection)
    func reset() {
        nonceGenerator.reset()
        expectedIncomingSequence = 0
    }

    /// Returns the current outgoing sequence number
    var currentOutgoingSequence: UInt64 {
        nonceGenerator.currentSequence
    }

    /// Returns the expected incoming sequence number
    var currentExpectedIncoming: UInt64 {
        expectedIncomingSequence
    }
}

// MARK: - Timestamp Encoding

/// Helper for encoding/decoding mosh packet timestamps
enum MoshTimestamp {
    /// Encodes two 16-bit timestamps into 4 bytes
    /// - Parameters:
    ///   - current: Current timestamp (ms mod 65536)
    ///   - reply: Echo reply timestamp (ms mod 65536)
    /// - Returns: 4-byte encoded timestamps
    nonisolated static func encode(current: UInt16, reply: UInt16) -> Data {
        var data = Data(count: 4)
        data[0] = UInt8(current >> 8)
        data[1] = UInt8(current & 0xFF)
        data[2] = UInt8(reply >> 8)
        data[3] = UInt8(reply & 0xFF)
        return data
    }

    /// Decodes 4 bytes into two timestamps
    /// - Parameter data: The 4-byte timestamp data
    /// - Returns: (current, reply) timestamps
    nonisolated static func decode(_ data: Data) -> (current: UInt16, reply: UInt16)? {
        guard data.count >= 4 else { return nil }
        let current = UInt16(data[0]) << 8 | UInt16(data[1])
        let reply = UInt16(data[2]) << 8 | UInt16(data[3])
        return (current, reply)
    }

    /// Returns current time as a 16-bit timestamp (ms mod 65536)
    nonisolated static var now: UInt16 {
        // Use monotonic time.
        // Avoid 0xFFFF which is reserved as "no timestamp" sentinel.
        let ms = ProtocolTiming.monotonicNowMs()
        var ts = UInt16(ms & 0xFFFF)
        if ts == UInt16.max {
            ts &+= 1
        }
        return ts
    }
}
