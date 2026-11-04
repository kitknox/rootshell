//
//  SSHFPRecord.swift
//  rootshell
//
//  SSHFP host-key records (RFC 4255/6594/7479/8709): parsing, matching, and the
//  DNS wire format for DoH. Foundation + CryptoKit only so rootshellTests can
//  compile it.
//

import Foundation
import CryptoKit

/// DNSSEC state of an SSHFP answer.
nonisolated enum SSHFPDNSSECStatus: Sendable, Equatable {
    case secure, insecure, bogus
}

/// The SSHFP RRset for one hostname.
nonisolated struct SSHFPLookupResult: Sendable, Equatable {
    var records: [SSHFPRecord]
    var dnssec: SSHFPDNSSECStatus
}

/// Outcome of checking a presented host key against DNS.
nonisolated enum SSHFPVerdict: Sendable, Equatable {
    /// Lookup off, skipped or failed, or the key type has no SSHFP algorithm.
    case unavailable
    /// No records for the presented key's algorithm.
    case noRecords
    case match(validated: Bool)
    case mismatch(validated: Bool)
    case bogus

    /// Line appended to host-key prompts; nil when DNS has nothing to say.
    var promptLine: String? {
        switch self {
        case .unavailable, .noRecords: nil
        case .match(validated: true): "DNS: matches SSHFP record (DNSSEC-validated)"
        case .match(validated: false): "DNS: matches SSHFP record (not DNSSEC-validated)"
        case .mismatch(validated: true): "WARNING: key does not match the DNSSEC-validated SSHFP record"
        case .mismatch(validated: false): "WARNING: key does not match the SSHFP record in DNS"
        case .bogus: "WARNING: the DNS answer for this host failed DNSSEC validation"
        }
    }
}

nonisolated struct SSHFPRecord: Sendable, Equatable {
    static let sha1: UInt8 = 1
    static let sha256: UInt8 = 2

    let algorithm: UInt8
    let fingerprintType: UInt8
    let fingerprint: Data

    init(algorithm: UInt8, fingerprintType: UInt8, fingerprint: Data) {
        self.algorithm = algorithm
        self.fingerprintType = fingerprintType
        self.fingerprint = fingerprint
    }

    /// Parses SSHFP RDATA; nil when truncated or a known digest has the wrong length.
    init?(rdata: Data) {
        let bytes = [UInt8](rdata)
        guard bytes.count > 2 else { return nil }
        let digest = Data(bytes[2...])
        if let expected = Self.digestLength(bytes[1]), digest.count != expected { return nil }
        self.init(algorithm: bytes[0], fingerprintType: bytes[1], fingerprint: digest)
    }

    private static func digestLength(_ type: UInt8) -> Int? {
        switch type {
        case sha1: 20
        case sha256: 32
        default: nil
        }
    }

    /// SSHFP algorithm number for an SSH key type; nil when SSHFP defines none.
    static func algorithm(forKeyType keyType: String) -> UInt8? {
        switch keyType {
        case "ssh-rsa": 1
        case "ssh-dss": 2
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": 3
        case "ssh-ed25519": 4
        case "ssh-ed448": 6
        default: nil
        }
    }

    /// Matches a host key's wire blob against `result`. Records for other
    /// algorithms are ignored, and SHA-1 only counts when no SHA-256 record exists.
    static func evaluate(keyType: String, keyBlob: Data, result: SSHFPLookupResult?) -> SSHFPVerdict {
        guard let result else { return .unavailable }
        if result.dnssec == .bogus { return .bogus }
        guard let algorithm = algorithm(forKeyType: keyType) else { return .unavailable }

        let forKey = result.records.filter { $0.algorithm == algorithm }
        let sha256Records = forKey.filter { $0.fingerprintType == sha256 }
        let candidates: [SSHFPRecord]
        let digest: Data
        if sha256Records.isEmpty {
            candidates = forKey.filter { $0.fingerprintType == sha1 }
            digest = Data(Insecure.SHA1.hash(data: keyBlob))
        } else {
            candidates = sha256Records
            digest = Data(SHA256.hash(data: keyBlob))
        }
        guard !candidates.isEmpty else { return .noRecords }

        let validated = result.dnssec == .secure
        return candidates.contains { $0.fingerprint == digest }
            ? .match(validated: validated)
            : .mismatch(validated: validated)
    }

    /// False for IP literals, single labels, mDNS and tailnet names, which have
    /// no public SSHFP and shouldn't leave the device.
    static func shouldLookUp(hostname: String) -> Bool {
        var name = hostname.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard name.contains("."), !name.contains(":") else { return false }
        var address = in_addr()
        if inet_pton(AF_INET, name, &address) == 1 { return false }
        return !name.hasSuffix(".local") && !name.hasSuffix(".ts.net")
    }
}

/// Minimal DNS wire format for DoH (RFC 8484) SSHFP queries.
nonisolated enum SSHFPDNSMessage {
    static let recordType: UInt16 = 44

    /// RD + AD with an EDNS0 OPT carrying DO; some validating resolvers only
    /// report AD when DO is set. ID 0 keeps responses cacheable (RFC 8484).
    static func query(name: String) -> Data? {
        var trimmed = Substring(name)
        if trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }

        var bytes: [UInt8] = [0, 0, 0x01, 0x20, 0, 1, 0, 0, 0, 0, 0, 1]
        var nameLength = 1
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            let labelBytes = Array(label.utf8)
            guard (1...63).contains(labelBytes.count), labelBytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            bytes.append(UInt8(labelBytes.count))
            bytes += labelBytes
            nameLength += labelBytes.count + 1
        }
        guard nameLength <= 255 else { return nil }
        bytes += [0, 0, UInt8(recordType), 0, 1]
        bytes += [0, 0, 41, 0x04, 0xD0, 0, 0, 0x80, 0, 0, 0]
        return Data(bytes)
    }

    /// NOERROR and NXDOMAIN yield a (possibly empty) result with AD mapped to
    /// `.secure`; SERVFAIL, truncation and malformed answers yield nil.
    static func parse(response: Data) -> SSHFPLookupResult? {
        let bytes = [UInt8](response)
        guard bytes.count >= 12, bytes[2] & 0x80 != 0, bytes[2] & 0x02 == 0 else { return nil }
        let rcode = bytes[3] & 0x0F
        guard rcode == 0 || rcode == 3 else { return nil }

        let questionCount = Int(bytes[4]) << 8 | Int(bytes[5])
        let answerCount = Int(bytes[6]) << 8 | Int(bytes[7])
        var offset = 12
        for _ in 0..<questionCount {
            guard let end = skipName(bytes, from: offset), end + 4 <= bytes.count else { return nil }
            offset = end + 4
        }

        var records: [SSHFPRecord] = []
        for _ in 0..<answerCount {
            guard let end = skipName(bytes, from: offset), end + 10 <= bytes.count else { return nil }
            let type = UInt16(bytes[end]) << 8 | UInt16(bytes[end + 1])
            let dataLength = Int(bytes[end + 8]) << 8 | Int(bytes[end + 9])
            let dataStart = end + 10
            guard dataStart + dataLength <= bytes.count else { return nil }
            if type == recordType, let record = SSHFPRecord(rdata: Data(bytes[dataStart..<(dataStart + dataLength)])) {
                records.append(record)
            }
            offset = dataStart + dataLength
        }
        return SSHFPLookupResult(records: records, dnssec: bytes[3] & 0x20 != 0 ? .secure : .insecure)
    }

    private static func skipName(_ bytes: [UInt8], from start: Int) -> Int? {
        var position = start
        while position < bytes.count {
            let length = Int(bytes[position])
            if length == 0 { return position + 1 }
            if length & 0xC0 == 0xC0 { return position + 2 <= bytes.count ? position + 2 : nil }
            guard length <= 63 else { return nil }
            position += length + 1
        }
        return nil
    }
}
