//
//  TSSHSessionCredentials.swift
//  rootshell
//
//  trzsz-ssh session credentials for persistence and resume
//

import Foundation

/// Credentials for resuming a trzsz-ssh session after app relaunch
///
/// Contains the connection parameters and certificates needed to
/// reconnect directly to an existing tsshd server without spawning a new one.
struct TrzszSessionCredentials: Codable, Sendable {
    /// The host to connect to
    let host: String

    /// The UDP port tsshd is listening on
    let udpPort: Int

    /// When the session was created
    let createdAt: Date

    /// The terminal UUID this session belongs to
    let terminalId: UUID

    /// Display name for logging (e.g., "user@host")
    let displayName: String

    /// Transport mode (QUIC or KCP)
    let mode: TrzszServerInfo.Mode

    /// tsshd server version (for resume validation)
    var serverVersion: String?

    /// tsshd protocol version; absent in records written before it was saved.
    var protoVersion: Int? = nil

    // MARK: - QUIC Credentials (hex-encoded for JSON storage)

    /// Server certificate (hex-encoded)
    var serverCertHex: String?

    /// Client certificate (hex-encoded)
    var clientCertHex: String?

    /// Client private key (hex-encoded)
    var clientKeyHex: String?

    // MARK: - KCP Credentials (hex-encoded for JSON storage)

    /// KCP encryption password (hex-encoded)
    var kcpPassHex: String?

    /// KCP salt (hex-encoded)
    var kcpSaltHex: String?

    // MARK: - Bootstrap SSH Crypto (captured before SSH closes)

    /// SSH key exchange algorithm negotiated during bootstrap
    var bootstrapKeyExchange: String?

    /// SSH host key algorithm negotiated during bootstrap
    var bootstrapHostKey: String?

    /// SSH cipher algorithm negotiated during bootstrap
    var bootstrapCipher: String?

    /// SSH MAC algorithm negotiated during bootstrap
    var bootstrapMac: String?

    // MARK: - Proxy Authentication

    /// Proxy key (hex-encoded, 32 bytes for AES-256-GCM)
    var proxyKeyHex: String?

    /// Client session ID (incremented on each resume for unique connections)
    var clientId: UInt64

    /// Server session ID
    let serverId: UInt64

    /// Session ID for Attach() — saved after Shell() succeeds
    var sessionID: UInt64?

    /// Auxiliary exec sessions opened on this connection (a herdr control
    /// bridge, an auxiliary PTY). Nothing ever reattaches one, but an
    /// attachable tsshd keeps a departed client's sessions running, so a run
    /// that ends abruptly leaves them with nobody reading their output. The
    /// next run ends them by id. Absent in records written before this.
    var auxiliarySessionIDs: [UInt64]?

    /// First relay hop. Kept as its own field so older builds still read single-relay records.
    var relay: TrzszRelayCredentials? = nil
    /// Relay hops after `relay`, in order.
    var extraRelays: [TrzszRelayCredentials]? = nil
    var transportMTU: Int? = nil

    /// Every relay hop in order; the target connects through the last.
    var relayChain: [TrzszRelayCredentials] {
        get { relay.map { [$0] + (extraRelays ?? []) } ?? [] }
        set {
            relay = newValue.first
            let rest = Array(newValue.dropFirst())
            extraRelays = rest.isEmpty ? nil : rest
        }
    }

    // MARK: - TTL Configuration

    /// Maximum gap since the last successful connection before credentials
    /// are considered useless. Matches the tsshd server-side default
    /// AliveTimeout (86400s); once exceeded, the attachable server has
    /// exited and the saved key can't be reattached. The heartbeat that
    /// drives this check is tracked on the per-terminal autosaved window
    /// state (see `LeafData.trzszLastConnectedAt`), not the keychain —
    /// keychain writes are too expensive to use for periodic refreshes.
    ///
    /// Only `TrzszSession.attemptResume` consults this; startup keychain
    /// cleanup is purely orphan-based (no time threshold) so long-lived
    /// sessions are never evicted just for being old.
    static let maxAge: TimeInterval = 86400  // 24 hours

    /// Human-readable age of the credentials
    var age: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else {
            return "\(Int(interval / 86400))d"
        }
    }

    // MARK: - Initialization

    /// Creates credentials from server info (for new sessions)
    /// - Parameters:
    ///   - serverInfo: The server info from tsshd spawn
    ///   - host: The host to connect to
    ///   - terminalId: The terminal UUID
    ///   - displayName: Display name for logging
    init(
        serverInfo: TrzszServerInfo,
        host: String,
        terminalId: UUID,
        displayName: String,
        bootstrapKeyExchange: String? = nil,
        bootstrapHostKey: String? = nil,
        bootstrapCipher: String? = nil,
        bootstrapMac: String? = nil
    ) {
        self.host = host
        self.udpPort = serverInfo.port
        self.createdAt = Date()
        self.terminalId = terminalId
        self.displayName = displayName
        self.mode = serverInfo.mode
        self.serverVersion = serverInfo.serverVersion
        self.protoVersion = serverInfo.protoVersion
        self.clientId = serverInfo.clientId
        self.serverId = serverInfo.serverId

        // Store certificates and keys as hex strings
        self.serverCertHex = serverInfo.serverCert?.hexString
        self.clientCertHex = serverInfo.clientCert?.hexString
        self.clientKeyHex = serverInfo.clientKey?.hexString
        self.kcpPassHex = serverInfo.kcpPass?.hexString
        self.kcpSaltHex = serverInfo.kcpSalt?.hexString
        self.proxyKeyHex = serverInfo.proxyKey?.hexString
        self.bootstrapKeyExchange = bootstrapKeyExchange
        self.bootstrapHostKey = bootstrapHostKey
        self.bootstrapCipher = bootstrapCipher
        self.bootstrapMac = bootstrapMac
    }

    /// Creates credentials with explicit values (for updates)
    init(
        host: String,
        udpPort: Int,
        terminalId: UUID,
        displayName: String,
        mode: TrzszServerInfo.Mode,
        serverVersion: String? = nil,
        clientId: UInt64,
        serverId: UInt64,
        serverCertHex: String? = nil,
        clientCertHex: String? = nil,
        clientKeyHex: String? = nil,
        kcpPassHex: String? = nil,
        kcpSaltHex: String? = nil,
        proxyKeyHex: String? = nil,
        createdAt: Date? = nil,
        bootstrapKeyExchange: String? = nil,
        bootstrapHostKey: String? = nil,
        bootstrapCipher: String? = nil,
        bootstrapMac: String? = nil
    ) {
        self.host = host
        self.udpPort = udpPort
        self.createdAt = createdAt ?? Date()
        self.terminalId = terminalId
        self.displayName = displayName
        self.mode = mode
        self.serverVersion = serverVersion
        self.clientId = clientId
        self.serverId = serverId
        self.serverCertHex = serverCertHex
        self.clientCertHex = clientCertHex
        self.clientKeyHex = clientKeyHex
        self.kcpPassHex = kcpPassHex
        self.kcpSaltHex = kcpSaltHex
        self.proxyKeyHex = proxyKeyHex
        self.bootstrapKeyExchange = bootstrapKeyExchange
        self.bootstrapHostKey = bootstrapHostKey
        self.bootstrapCipher = bootstrapCipher
        self.bootstrapMac = bootstrapMac
    }

    // MARK: - Data Accessors

    /// Server certificate as Data (for QUIC)
    var serverCert: Data? {
        serverCertHex.flatMap { Data(hexString: $0) }
    }

    /// Client certificate as Data (for QUIC)
    var clientCert: Data? {
        clientCertHex.flatMap { Data(hexString: $0) }
    }

    /// Client private key as Data (for QUIC)
    var clientKey: Data? {
        clientKeyHex.flatMap { Data(hexString: $0) }
    }

    /// KCP password as Data
    var kcpPass: Data? {
        kcpPassHex.flatMap { Data(hexString: $0) }
    }

    /// KCP salt as Data
    var kcpSalt: Data? {
        kcpSaltHex.flatMap { Data(hexString: $0) }
    }

    /// Proxy key as Data
    var proxyKey: Data? {
        proxyKeyHex.flatMap { Data(hexString: $0) }
    }
}

// MARK: - Conversion to ServerInfo

extension TrzszSessionCredentials {
    /// Converts credentials back to TrzszServerInfo for Go transport resume
    func toServerInfo() -> TrzszServerInfo {
        TrzszServerInfo(
            serverVersion: serverVersion ?? "0.1.6",
            protoVersion: protoVersion,
            port: udpPort,
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
}

// MARK: - CustomStringConvertible

extension TrzszSessionCredentials: CustomStringConvertible {
    var description: String {
        let certPrefix = (serverCertHex ?? "").prefix(8)
        return "TrzszCredentials(\(displayName), port=\(udpPort), mode=\(mode.rawValue), cert=\(certPrefix)..., age=\(age))"
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

/// The outer server has no PTY; reconnect it with a fresh attachable client ID.
struct TrzszRelayCredentials: Codable, Sendable {
    let host: String
    var serverInfo: TrzszServerInfo
    let mtu: Int
    let targetMTU: Int
    var connectTimeoutSec: Int? = nil
}
