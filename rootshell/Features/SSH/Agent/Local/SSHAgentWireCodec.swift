// Compiled into the Catalyst Standalone app and the native-macOS rootshellvpn
// host (external-agent signing broker) — keep this file pure Foundation/Darwin.
#if (targetEnvironment(macCatalyst) && STANDALONE) || os(macOS)

import Foundation
import Darwin

nonisolated enum SSHAgentWireCodec {
    static let maxFrameLength = 256 * 1024
    /// OpenSSH ssh-agent's AGENT_MAX_SID_LEN and AGENT_MAX_SESSION_IDS.
    static let maxSessionIDLength = 128
    static let maxSessionBinds = 16

    enum MessageType: UInt8 {
        case failure = 5
        case success = 6
        case requestIdentities = 11
        case identitiesAnswer = 12
        case signRequest = 13
        case signResponse = 14
        case addIdentity = 17
        case removeIdentity = 18
        case removeAllIdentities = 19
        case lock = 22
        case unlock = 23
        case addIdentityConstrained = 25
        case extensionRequest = 27
    }

    enum Constraint: Sendable, Equatable {
        case lifetime(UInt32)
        case confirm
        case extensionConstraint(String, Data)
        case unknown(UInt8, Data)
    }

    struct AddedIdentity: Sendable, Equatable {
        enum KeyMaterial: Sendable, Equatable {
            case ed25519(publicKey: Data, seed: Data)
            case ecdsa(curve: String, publicKey: Data, scalar: Data)
            case rsa(n: Data, e: Data, d: Data)
            /// ML-DSA family (hybrid + pure): raw public key bytes and the
            /// seed-form private key (64 bytes for the hybrid, 32 for pure).
            case mldsa(keyType: String, publicKey: Data, seeds: Data)
            case unsupported(String)
        }

        var keyType: String
        var comment: String
        var publicKeyBlob: Data
        var material: KeyMaterial
    }

    enum Request: Sendable, Equatable {
        case listIdentities
        case sign(keyBlob: Data, data: Data, flags: UInt32)
        case sessionBind(hostKeyBlob: Data, sessionID: Data, signature: Data, isForwarding: Bool)
        case addIdentity(AddedIdentity, constraints: [Constraint])
        case removeIdentity(keyBlob: Data)
        case removeAll
        case lock(passphrase: Data)
        case unlock(passphrase: Data)
        case unsupported(UInt8)
    }

    /// The only requests permitted while locked are binding and unlocking.
    /// Identity enumeration succeeds with an empty list, as in OpenSSH.
    static func responseWhileLocked(to request: Request) -> Data? {
        switch request {
        case .sessionBind, .unlock:
            return nil
        case .listIdentities:
            return identitiesAnswer([])
        default:
            return failureFrame
        }
    }

    struct Identity: Sendable, Equatable, Identifiable {
        var id: Data { publicKeyBlob }
        var publicKeyBlob: Data
        var comment: String
    }

    static func parse(frame: Data) -> Request {
        guard let type = frame.first else { return .unsupported(0) }
        var reader = SSHAgentReader(Data(frame.dropFirst()))

        switch type {
        case MessageType.requestIdentities.rawValue:
            return .listIdentities
        case MessageType.signRequest.rawValue:
            guard let keyBlob = reader.readStringData(),
                  let data = reader.readStringData(),
                  let flags = reader.readUInt32() else {
                return .unsupported(type)
            }
            return .sign(keyBlob: keyBlob, data: data, flags: flags)
        case MessageType.extensionRequest.rawValue:
            guard let name = reader.readString() else { return .unsupported(type) }
            // PROTOCOL.agent: string hostkey, string session id, string signature, bool is_forwarding.
            if name == "session-bind@openssh.com",
               let hostKeyBlob = reader.readStringData(),
               let sessionID = reader.readStringData(),
               sessionID.count <= maxSessionIDLength,
               let signature = reader.readStringData(),
               let forwardingByte = reader.readUInt8() {
                return .sessionBind(
                    hostKeyBlob: hostKeyBlob,
                    sessionID: sessionID,
                    signature: signature,
                    isForwarding: forwardingByte != 0
                )
            }
            return .unsupported(type)
        case MessageType.addIdentity.rawValue, MessageType.addIdentityConstrained.rawValue:
            guard let identity = parseAddedIdentity(reader: &reader) else {
                return .unsupported(type)
            }
            let constraints = type == MessageType.addIdentityConstrained.rawValue
                ? parseConstraints(reader: &reader)
                : []
            return .addIdentity(identity, constraints: constraints)
        case MessageType.removeIdentity.rawValue:
            guard let keyBlob = reader.readStringData() else { return .unsupported(type) }
            return .removeIdentity(keyBlob: keyBlob)
        case MessageType.removeAllIdentities.rawValue:
            return .removeAll
        case MessageType.lock.rawValue:
            guard let passphrase = reader.readStringData() else { return .unsupported(type) }
            return .lock(passphrase: passphrase)
        case MessageType.unlock.rawValue:
            guard let passphrase = reader.readStringData() else { return .unsupported(type) }
            return .unlock(passphrase: passphrase)
        default:
            return .unsupported(type)
        }
    }

    static func identitiesAnswer(_ identities: [Identity]) -> Data {
        var writer = SSHAgentWriter()
        writer.writeByte(MessageType.identitiesAnswer.rawValue)
        writer.writeUInt32(UInt32(identities.count))
        for identity in identities {
            writer.writeString(identity.publicKeyBlob)
            writer.writeString(identity.comment)
        }
        return wrap(writer.data)
    }

    static func signResponse(_ signatureBlob: Data) -> Data {
        var writer = SSHAgentWriter()
        writer.writeByte(MessageType.signResponse.rawValue)
        writer.writeString(signatureBlob)
        return wrap(writer.data)
    }

    static var failureFrame: Data {
        wrap(Data([MessageType.failure.rawValue]))
    }

    static var successFrame: Data {
        wrap(Data([MessageType.success.rawValue]))
    }

    // MARK: - Client direction (app connecting to an external agent)

    /// Response from an external agent, as seen by an agent client.
    enum ClientResponse: Sendable, Equatable {
        case identities([Identity])
        case signature(Data)
        case failure
        case unknown(UInt8)
    }

    static var requestIdentitiesFrame: Data {
        wrap(Data([MessageType.requestIdentities.rawValue]))
    }

    static func signRequestFrame(keyBlob: Data, data: Data, flags: UInt32) -> Data {
        var writer = SSHAgentWriter()
        writer.writeByte(MessageType.signRequest.rawValue)
        writer.writeString(keyBlob)
        writer.writeString(data)
        writer.writeUInt32(flags)
        return wrap(writer.data)
    }

    static func parseClientResponse(frame: Data) -> ClientResponse {
        guard let type = frame.first else { return .unknown(0) }
        var reader = SSHAgentReader(Data(frame.dropFirst()))

        switch type {
        case MessageType.identitiesAnswer.rawValue:
            guard let count = reader.readUInt32() else { return .unknown(type) }
            var identities: [Identity] = []
            for _ in 0..<count {
                guard let blob = reader.readStringData(),
                      let comment = reader.readString() else { return .unknown(type) }
                identities.append(Identity(publicKeyBlob: blob, comment: comment))
            }
            return .identities(identities)
        case MessageType.signResponse.rawValue:
            guard let signature = reader.readStringData() else { return .unknown(type) }
            return .signature(signature)
        case MessageType.failure.rawValue:
            return .failure
        default:
            return .unknown(type)
        }
    }

    static func readFrame(fd: Int32) -> Data? {
        var lenBytes = [UInt8](repeating: 0, count: 4)
        guard readExact(fd: fd, buffer: &lenBytes, count: 4) else { return nil }
        let length =
            (UInt32(lenBytes[0]) << 24) |
            (UInt32(lenBytes[1]) << 16) |
            (UInt32(lenBytes[2]) << 8) |
            UInt32(lenBytes[3])
        guard length > 0, length <= maxFrameLength else { return nil }
        var body = [UInt8](repeating: 0, count: Int(length))
        guard readExact(fd: fd, buffer: &body, count: Int(length)) else { return nil }
        return Data(body)
    }

    static func writeFrame(fd: Int32, frame: Data) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < frame.count {
                let n = Darwin.write(fd, base + offset, frame.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                offset += n
            }
        }
    }

    private static func wrap(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    private static func readExact(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress! + total, count - total)
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            total += n
        }
        return true
    }

    private static func parseAddedIdentity(reader: inout SSHAgentReader) -> AddedIdentity? {
        guard let keyType = reader.readString() else { return nil }
        let publicBlobStart = SSHAgentWriter.publicKeyBlobPrefix(keyType)

        switch keyType {
        case "ssh-ed25519":
            guard let publicKey = reader.readStringData(),
                  let privateKey = reader.readStringData(),
                  let comment = reader.readString() else { return nil }
            let seed = Data(privateKey.prefix(32))
            var blob = publicBlobStart
            SSHAgentWriter.appendString(publicKey, to: &blob)
            return AddedIdentity(
                keyType: keyType,
                comment: comment,
                publicKeyBlob: blob,
                material: .ed25519(publicKey: publicKey, seed: seed)
            )
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let curve = reader.readString(),
                  let publicKey = reader.readStringData(),
                  let scalar = reader.readMPInt(),
                  let comment = reader.readString() else { return nil }
            var blob = publicBlobStart
            SSHAgentWriter.appendString(curve, to: &blob)
            SSHAgentWriter.appendString(publicKey, to: &blob)
            return AddedIdentity(
                keyType: keyType,
                comment: comment,
                publicKeyBlob: blob,
                material: .ecdsa(curve: curve, publicKey: publicKey, scalar: scalar)
            )
        case "ssh-mldsa44-ed25519", "ssh-mldsa44-ed25519@openssh.com", "ssh-mldsa44", "ssh-mldsa65", "ssh-mldsa87":
            // Private serialization: string pk || string sk (seed form —
            // 64 bytes for the hybrid, 32 for pure; matches OpenSSH 10.4's
            // hybrid and this app's pure-key convention).
            guard let publicKey = reader.readStringData(),
                  let seeds = reader.readStringData(),
                  let comment = reader.readString() else { return nil }
            var blob = publicBlobStart
            SSHAgentWriter.appendString(publicKey, to: &blob)
            return AddedIdentity(
                keyType: keyType,
                comment: comment,
                publicKeyBlob: blob,
                material: .mldsa(keyType: keyType, publicKey: publicKey, seeds: seeds)
            )
        case "ssh-rsa":
            guard let n = reader.readMPInt(),
                  let e = reader.readMPInt(),
                  let d = reader.readMPInt(),
                  reader.readMPInt() != nil,
                  reader.readMPInt() != nil,
                  reader.readMPInt() != nil,
                  let comment = reader.readString(),
                  rsaKeyIsPlausible(n: n, e: e, d: d) else { return nil }
            var blob = publicBlobStart
            SSHAgentWriter.appendMPInt(e, to: &blob)
            SSHAgentWriter.appendMPInt(n, to: &blob)
            return AddedIdentity(
                keyType: keyType,
                comment: comment,
                publicKeyBlob: blob,
                material: .rsa(n: n, e: e, d: d)
            )
        default:
            return AddedIdentity(
                keyType: keyType,
                comment: reader.readString() ?? keyType,
                publicKeyBlob: publicBlobStart,
                material: .unsupported(keyType)
            )
        }
    }

    /// OpenSSH's RSA limits (3e2bbf871): modulus 1024-16384 bits, odd e >= 3, 0 < d < n.
    static func rsaKeyIsPlausible(n: Data, e: Data, d: Data) -> Bool {
        let modulusBits = bitLength(n)
        guard modulusBits >= 1024, modulusBits <= 16384,
              let lastE = e.last, lastE & 1 == 1, bitLength(e) >= 2, bitLength(e) <= modulusBits,
              bitLength(d) > 0, bitLength(d) <= modulusBits else {
            return false
        }
        return true
    }

    /// Bit length of a big-endian unsigned integer, ignoring leading zero bytes.
    private static func bitLength(_ bytes: Data) -> Int {
        guard let index = bytes.firstIndex(where: { $0 != 0 }) else { return 0 }
        let significant = bytes.distance(from: index, to: bytes.endIndex)
        return (significant - 1) * 8 + (8 - bytes[index].leadingZeroBitCount)
    }

    private static func parseConstraints(reader: inout SSHAgentReader) -> [Constraint] {
        var constraints: [Constraint] = []
        while !reader.isAtEnd {
            guard let type = reader.readUInt8() else { break }
            switch type {
            case 1:
                if let seconds = reader.readUInt32() { constraints.append(.lifetime(seconds)) }
            case 2:
                constraints.append(.confirm)
            case 255:
                if let name = reader.readString(), let data = reader.readStringData() {
                    constraints.append(.extensionConstraint(name, data))
                }
            default:
                let remaining = reader.readRemaining()
                constraints.append(.unknown(type, remaining))
                return constraints
            }
        }
        return constraints
    }
}

nonisolated struct SSHAgentReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readUInt8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value =
            (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
        offset += 4
        return value
    }

    mutating func readString() -> String? {
        guard let bytes = readStringData() else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    mutating func readStringData() -> Data? {
        guard let length = readUInt32(), length <= SSHAgentWireCodec.maxFrameLength else { return nil }
        let count = Int(length)
        guard offset + count <= data.count else { return nil }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    mutating func readMPInt() -> Data? {
        guard var value = readStringData() else { return nil }
        while value.first == 0, value.count > 1 {
            value.removeFirst()
        }
        return value
    }

    mutating func readRemaining() -> Data {
        guard offset < data.count else { return Data() }
        defer { offset = data.count }
        return Data(data[offset..<data.count])
    }
}

nonisolated struct SSHAgentWriter {
    private(set) var data = Data()

    mutating func writeByte(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }

    mutating func writeString(_ value: String) {
        writeString(Data(value.utf8))
    }

    mutating func writeString(_ value: Data) {
        Self.appendString(value, to: &data)
    }

    static func appendString(_ value: String, to data: inout Data) {
        appendString(Data(value.utf8), to: &data)
    }

    static func appendString(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(value)
    }

    static func appendMPInt(_ value: Data, to data: inout Data) {
        var bytes = Array(value)
        while bytes.first == 0, bytes.count > 1 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        appendString(Data(bytes), to: &data)
    }

    static func publicKeyBlobPrefix(_ keyType: String) -> Data {
        var blob = Data()
        appendString(keyType, to: &blob)
        return blob
    }
}

#endif
