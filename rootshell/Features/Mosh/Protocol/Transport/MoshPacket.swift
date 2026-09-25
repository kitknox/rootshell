//
//  MoshPacket.swift
//  rootshell
//
//  Mosh packet serialization and parsing
//

import Foundation

/// Represents a mosh protocol packet
///
/// Wire format (after encryption):
/// ```
/// +---------------------------+
/// | 8 bytes: Nonce (clear)    |
/// +---------------------------+
/// | Encrypted payload:        |
/// |   4 bytes: Timestamps     |
/// |  10 bytes: Fragment header|
/// |   N bytes: Instruction    |
/// +---------------------------+
/// | 16 bytes: OCB Auth Tag    |
/// +---------------------------+
/// ```
struct MoshPacket: Sendable {

    /// Packet direction
    let direction: MoshNonce.Direction

    /// Sequence number from nonce
    let sequenceNumber: UInt64

    /// Current timestamp (sender's time, ms mod 65536)
    let timestamp: UInt16

    /// Echo reply timestamp (echoing received timestamp)
    let replyTimestamp: UInt16

    /// The instruction payload (TransportInstruction protobuf)
    let payload: Data

    // MARK: - Initialization

    /// Creates a packet for sending
    /// - Parameters:
    ///   - direction: Packet direction
    ///   - sequenceNumber: Sequence number
    ///   - timestamp: Current timestamp
    ///   - replyTimestamp: Echo reply timestamp
    ///   - payload: The instruction payload
    init(
        direction: MoshNonce.Direction,
        sequenceNumber: UInt64,
        timestamp: UInt16,
        replyTimestamp: UInt16,
        payload: Data
    ) {
        self.direction = direction
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.replyTimestamp = replyTimestamp
        self.payload = payload
    }

    // MARK: - Serialization

    /// Serializes the packet plaintext (timestamps + fragment + payload) for encryption
    /// Note: MoshTransport.send() handles this directly now
    var plaintext: Data {
        var data = Data()
        // Timestamps (4 bytes)
        data.append(MoshTimestamp.encode(current: timestamp, reply: replyTimestamp))
        // Fragment header + payload (we create a single fragment)
        let fragment = MoshFragment(
            fragmentId: UInt64.random(in: 0..<UInt64.max),
            fragmentNum: 0,
            isFinal: true,
            payload: payload
        )
        data.append(fragment.serialized)
        return data
    }

    /// Parses a decrypted packet
    /// - Parameters:
    ///   - plaintext: The decrypted plaintext
    ///   - nonce: The nonce from the packet
    /// - Returns: Parsed packet
    /// - Throws: MoshError.invalidPacketFormat if parsing fails
    static func parse(plaintext: Data, nonce: MoshNonce) throws -> MoshPacket {
        // Need at least 4 bytes timestamps + 10 bytes fragment header = 14 bytes
        guard plaintext.count >= 14 else {
            throw MoshError.invalidPacketFormat(
                reason: "Packet plaintext too short: \(plaintext.count) bytes (need at least 14)"
            )
        }

        // Parse timestamps (first 4 bytes)
        guard let (timestamp, replyTimestamp) = MoshTimestamp.decode(plaintext) else {
            throw MoshError.invalidPacketFormat(reason: "Failed to decode timestamps")
        }

        // Parse fragment (everything after 4-byte timestamp)
        let fragmentAndPayload = Data(plaintext.suffix(from: 4))
        let fragment = try MoshFragment.parse(fragmentAndPayload)

        // TODO: Handle multi-fragment messages with fragment assembler
        // For now, we only support single-fragment messages
        guard fragment.isSingle else {
            throw MoshError.invalidPacketFormat(
                reason: "Multi-fragment messages not yet supported"
            )
        }

        // The payload is the fragment payload (protobuf instruction)
        let payload = fragment.payload

        return MoshPacket(
            direction: nonce.direction,
            sequenceNumber: nonce.sequenceNumber,
            timestamp: timestamp,
            replyTimestamp: replyTimestamp,
            payload: payload
        )
    }

    // MARK: - Packet Info

    /// Returns the nonce for this packet
    var nonce: MoshNonce {
        MoshNonce(direction: direction, sequenceNumber: sequenceNumber)
    }

    /// Minimum encrypted packet size (8 nonce + 4 timestamps + 16 tag)
    static let minimumSize = 28

    /// Whether this packet has a payload
    var hasPayload: Bool {
        !payload.isEmpty
    }
}

// MARK: - Packet Builder

/// Builder for creating outgoing mosh packets
struct MoshPacketBuilder {
    private let direction: MoshNonce.Direction
    // 0xFFFF indicates "no timestamp reply" (sentinel).
    private var replyTimestamp: UInt16 = UInt16.max

    /// Creates a builder for the specified direction
    init(direction: MoshNonce.Direction) {
        self.direction = direction
    }

    /// Sets the echo reply timestamp (from last received packet)
    mutating func setReplyTimestamp(_ timestamp: UInt16) {
        self.replyTimestamp = timestamp
    }

    var currentReplyTimestamp: UInt16 {
        replyTimestamp
    }

    /// Builds a packet with the given payload
    /// - Parameters:
    ///   - payload: The instruction payload
    ///   - sequenceNumber: The sequence number (from nonce generator)
    /// - Returns: The built packet
    func build(payload: Data, sequenceNumber: UInt64) -> MoshPacket {
        MoshPacket(
            direction: direction,
            sequenceNumber: sequenceNumber,
            timestamp: MoshTimestamp.now,
            replyTimestamp: replyTimestamp,
            payload: payload
        )
    }

    /// Builds a heartbeat packet (empty payload)
    func buildHeartbeat(sequenceNumber: UInt64) -> MoshPacket {
        build(payload: Data(), sequenceNumber: sequenceNumber)
    }
}
