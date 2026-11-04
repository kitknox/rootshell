//
//  TSSHServerInfo.swift
//  rootshell
//
//  Parses JSON output from tsshd server spawn
//

import Foundation

/// Server information returned by tsshd on spawn
///
/// tsshd outputs JSON to stdout containing connection parameters:
/// ```json
/// {
///   "ServerVer": "v1.0",
///   "Port": 61001,
///   "Mode": "QUIC",
///   "ServerCert": "<hex>",
///   "ClientCert": "<hex>",
///   "ClientKey": "<hex>",
///   "ClientID": 123456,
///   "ServerID": 789012
/// }
/// ```
///
/// For KCP mode, different fields are present:
/// ```json
/// {
///   "ServerVer": "v1.0",
///   "Port": 61001,
///   "Mode": "KCP",
///   "Pass": "<hex>",
///   "Salt": "<hex>",
///   "ProxyKey": "<hex>",
///   "ClientID": 123456,
///   "ServerID": 789012
/// }
/// ```
struct TrzszServerInfo: Codable, Sendable {
    /// Server version string
    let serverVersion: String

    /// `ProtoVer`; nil when the server or a saved record predates it. Protocol 2 enables zstd output.
    var protoVersion: Int? = nil

    /// UDP port the server is listening on
    let port: Int

    /// Transport mode
    let mode: Mode

    /// Transport mode enum
    enum Mode: String, Codable, Sendable {
        case quic = "QUIC"
        case kcp = "KCP"
    }

    // MARK: - QUIC Credentials (only present in QUIC mode)

    /// Server certificate (DER format, hex-encoded from server)
    let serverCert: Data?

    /// Client certificate (DER format, hex-encoded from server)
    let clientCert: Data?

    /// Client private key (DER format, hex-encoded from server)
    let clientKey: Data?

    // MARK: - KCP Credentials (only present in KCP mode)

    /// KCP encryption password (for AES-GCM key derivation)
    let kcpPass: Data?

    /// KCP salt (for AES-GCM key derivation)
    let kcpSalt: Data?

    // MARK: - Proxy Authentication (common to all modes)

    /// Proxy authentication key (32 bytes for AES-256-GCM)
    /// Used for NAT traversal and roaming authentication
    let proxyKey: Data?

    /// Client ID for proxy authentication. When 0 (attachable mode), the client generates a random value.
    /// Incremented on each resume to ensure unique connections.
    var clientId: UInt64

    /// Server session ID (for proxy authentication during reconnect)
    let serverId: UInt64

    // MARK: - Parsing

    /// Parses server info from JSON string
    /// - Parameter json: The JSON string output from tsshd
    /// - Throws: TrzszError.invalidServerInfo if parsing fails
    static func parse(from json: String) throws -> TrzszServerInfo {
        guard let data = json.data(using: .utf8) else {
            throw TrzszError.invalidServerInfo(reason: "Invalid UTF-8 data")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrzszError.invalidServerInfo(reason: "Expected JSON object")
        }

        // Required fields
        guard let serverVersion = object["ServerVer"] as? String else {
            throw TrzszError.invalidServerInfo(reason: "Missing ServerVer")
        }

        let protoVersion = object["ProtoVer"] as? Int

        guard let port = object["Port"] as? Int else {
            throw TrzszError.invalidServerInfo(reason: "Missing Port")
        }

        guard let modeString = object["Mode"] as? String,
              let mode = Mode(rawValue: modeString) else {
            throw TrzszError.invalidServerInfo(reason: "Missing or invalid Mode")
        }

        // ClientID is 0 (absent) in attachable mode — client must generate one
        let clientId = try parseID(object, key: "ClientID")

        // ServerID may also be absent in attachable mode
        let serverId = try parseID(object, key: "ServerID")

        // Proxy key (common to both modes)
        var proxyKey: Data?
        if let proxyKeyHex = object["ProxyKey"] as? String {
            proxyKey = Data(hexString: proxyKeyHex)
        }

        // Mode-specific credentials
        var serverCert: Data?
        var clientCert: Data?
        var clientKey: Data?
        var kcpPass: Data?
        var kcpSalt: Data?

        switch mode {
        case .quic:
            if let serverCertHex = object["ServerCert"] as? String {
                serverCert = Data(hexString: serverCertHex)
            }
            if let clientCertHex = object["ClientCert"] as? String {
                clientCert = Data(hexString: clientCertHex)
            }
            if let clientKeyHex = object["ClientKey"] as? String {
                clientKey = Data(hexString: clientKeyHex)
            }

        case .kcp:
            // KCP mode uses "Pass" and "Salt" field names (not "KCPPass"/"KCPSalt")
            if let passHex = object["Pass"] as? String {
                kcpPass = Data(hexString: passHex)
            }
            if let saltHex = object["Salt"] as? String {
                kcpSalt = Data(hexString: saltHex)
            }
        }

        return TrzszServerInfo(
            serverVersion: serverVersion,
            protoVersion: protoVersion,
            port: port,
            mode: mode,
            serverCert: serverCert,
            clientCert: clientCert,
            clientKey: clientKey,
            kcpPass: kcpPass,
            kcpSalt: kcpSalt,
            proxyKey: proxyKey,
            clientId: clientId,
            serverId: serverId
        )
    }

    /// Absent IDs default to 0; present ones must be non-negative integers.
    /// NSNumber bridging to UInt64 is exact, so negatives and fractions fail here instead of trapping.
    private static func parseID(_ object: [String: Any], key: String) throws -> UInt64 {
        guard let value = object[key] else { return 0 }
        guard let id = value as? UInt64 else {
            throw TrzszError.invalidServerInfo(reason: "Invalid \(key)")
        }
        return id
    }

    /// Extracts JSON from output that may contain other text
    /// Looks for the first `{` and last `}` to extract the JSON object
    /// - Parameter output: Raw stdout output from SSH command
    /// - Returns: Parsed server info
    /// - Throws: TrzszError.invalidServerInfo if no valid JSON found
    static func parse(fromOutput output: String) throws -> TrzszServerInfo {
        guard let jsonStart = output.firstIndex(of: "{"),
              let jsonEnd = output[jsonStart...].lastIndex(of: "}") else {
            throw TrzszError.invalidServerInfo(reason: "No JSON object found in output")
        }

        let jsonString = String(output[jsonStart...jsonEnd])
        return try parse(from: jsonString)
    }
}

// MARK: - Data Hex Extension

private extension Data {
    /// Initialize Data from hex string
    init?(hexString: String) {
        let cleanHex = hexString.replacingOccurrences(of: " ", with: "")
        var data = Data(capacity: cleanHex.count / 2)

        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2, limitedBy: cleanHex.endIndex) ?? cleanHex.endIndex
            let byteString = cleanHex[index..<nextIndex]
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }

        self = data
    }

    /// Convert Data to hex string
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
