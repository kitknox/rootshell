//
//  VPNTunnelConfig.swift
//  rootshell
//
//  Runtime VPN config resolved from the shared VPN profile mirror.
//

import Foundation

/// A credential resolved by the host in user context and handed to the tunnel.
/// Used on macOS, where the packet-tunnel runs as a root system extension that
/// cannot read the per-user login keychain: the host resolves the real secret
/// and pushes it via `startTunnel(options:)`. `nil` on iOS/Catalyst, where the
/// in-process appex reads the keychain directly.
nonisolated enum VPNResolvedCredential: Codable, Sendable, Hashable {
    case password(String)
    case key(privateKey: String, passphrase: String?)
    /// macOS only: a key served by an external OpenSSH agent. There is no
    /// secret to push — the sysext offers the public blob and requests each
    /// userauth signature from the host over the agent signing broker
    /// (`agent.poll` / `agent.submit` provider messages). `socketPath` is
    /// carried so the host knows which agent to sign against.
    case agentKey(publicKeyBlob: Data, algorithm: String, socketPath: String)
}

/// Wire payload the macOS host encodes into `startTunnel(options:)`: the
/// non-secret profile snapshot plus resolved secrets for the target and jump host.
nonisolated struct VPNResolvedConfig: Codable, Sendable {
    var snapshot: VPNSharedProfileSnapshot
    var credential: VPNResolvedCredential?
    var jumpCredential: VPNResolvedCredential?
    /// Hops after the first, index-aligned with `snapshot.extraJumpHosts`.
    var extraJumpCredentials: [VPNResolvedCredential?]? = nil
    /// Tailscale tunnels only: the sysext can't read the app group either.
    var tailnet: VPNResolvedTailnet? = nil
}

/// Tailscale settings and the resolved SSH egress host, if one is set.
nonisolated struct VPNResolvedTailnet: Codable, Sendable {
    var settings: VPNTailnetSettings
    var egress: VPNSharedProfileSnapshot?
    var egressCredential: VPNResolvedCredential?
    var egressJumpCredential: VPNResolvedCredential?
    var egressExtraJumpCredentials: [VPNResolvedCredential?]? = nil
    /// Node state the in-app engine last used; replaces the sysext's copy so
    /// both modes stay one device.
    var importState: [String: Data]? = nil
    /// Come up without Tailscale or routes, only so the app can read the node state.
    var exportOnly: Bool? = nil
    /// `TailnetAuthKey`, which the sysext can't read either.
    var authKey: String? = nil
}

/// Runtime VPN tunnel config resolved inside the extension from the shared profile mirror.
struct VPNTunnelConfig: Codable, Sendable {
    let profileID: UUID
    let profileName: String
    let transportType: TransportType

    // SSH-specific
    let sshHost: String
    let sshPort: Int
    let sshUsername: String
    let sshAuth: VPNSharedProfileAuth
    let jumpHostConfig: JumpHostTunnelConfig?
    // Hops after jumpHostConfig, in order.
    var extraJumpHostConfigs: [JumpHostTunnelConfig]? = nil
    // Host key the user accepted in a terminal session, and/or trusted host-CA
    // keys covering the host. The connector refuses to dial without at least
    // one of them and fails the connect if the server verifies against neither.
    var pinnedHostKey: VPNPinnedHostKey? = nil
    var trustedCAKeys: [String]? = nil

    // TSSH-specific
    let trzszMode: String?  // "KCP" or "QUIC"
    let trzszUDPPortMin: Int?
    let trzszUDPPortMax: Int?
    let trzszMTU: Int?  // Packet MTU (separate from TUN device mtu)
    let trzszConnectTimeoutSec: Int?
    let trzszServerPath: String?  // Full path to remote tsshd binary (nil = "tsshd" via PATH)

    // Shared
    let dnsServers: [String]
    let excludedRoutes: [String]  // CIDRs to exclude from tunnel
    let mtu: Int

    // Reject QUIC (UDP 443) with ICMP so browsers fall back to HTTP/2.
    // The Go bridge also auto-enables this when the transport's datagram
    // budget is too small to carry QUIC packets.
    var blockQUIC: Bool = false

    // Halved SSH channel windows, for SSH egress beside Tailscale.
    var compactChannelWindows: Bool = false

    // Secrets pushed by the macOS host (nil on iOS/Catalyst — the keychain is
    // read in-process). When set, VPNSSHConnector uses these instead of the
    // shared keychain, which a root system extension cannot access.
    var resolvedCredential: VPNResolvedCredential? = nil
    var jumpResolvedCredential: VPNResolvedCredential? = nil
    var extraJumpResolvedCredentials: [VPNResolvedCredential?]? = nil

    enum TransportType: String, Codable, Sendable {
        case ssh
        case tssh
        case direct
        /// Tailscale, optionally with an SSH egress host (iOS only).
        case tailscale
    }

    /// Jump host config subset needed by the extension
    struct JumpHostTunnelConfig: Codable, Sendable {
        var tsshRelay: TSSHRelaySettings? = nil
        let host: String
        let port: Int
        let username: String
        let auth: VPNSharedProfileAuth
        var pinnedHostKey: VPNPinnedHostKey? = nil
        var trustedCAKeys: [String]? = nil
    }

    /// Every jump hop in connection order.
    var jumpChain: [JumpHostTunnelConfig] {
        jumpHostConfig.map { [$0] + (extraJumpHostConfigs ?? []) } ?? []
    }

    /// Resolved secret for hop `index` (0 is jumpHostConfig); nil on iOS.
    func jumpResolvedCredential(at index: Int) -> VPNResolvedCredential? {
        if index == 0 { return jumpResolvedCredential }
        guard let extras = extraJumpResolvedCredentials, extras.indices.contains(index - 1) else { return nil }
        return extras[index - 1]
    }

    /// TSSH server info obtained at runtime by the extension after spawning tsshd.
    /// These fields are populated by the extension, not by the main app.
    struct TSSHServerInfo: Codable, Sendable {
        let serverVersion: String
        let port: Int
        let mode: String  // "KCP" or "QUIC"
        let pass: String?
        let salt: String?
        let serverCert: String?
        let clientCert: String?
        let clientKey: String?
        let proxyKey: String?
        let clientID: UInt64
        let serverID: UInt64
    }

    /// Serialize to JSON string (for passing to Go bridge).
    /// For SSH profiles, the extension passes the SOCKS5 proxy address after starting it.
    /// For TSSH profiles, the extension passes tsshd server info after spawning.
    /// - Parameters:
    ///   - socks5Address: SOCKS5 proxy address for SSH mode
    ///   - tsshServerInfo: Server info from tsshd spawn for TSSH mode
    ///   - resolvedHost: Pre-resolved IP address to use as tsshHost (overrides sshHost)
    func toGoConfigJSON(socks5Address: String? = nil, tsshServerInfo: TSSHServerInfo? = nil, resolvedHost: String? = nil, transportMTU: Int? = nil, relayRequired: Bool? = nil) throws -> String {
        struct GoConfig: Codable {
            let transportType: String
            // TSSH fields
            let tsshRelayRequired: Bool?
            let tsshHost: String?
            let tsshPort: Int?
            let tsshMode: String?
            let tsshServerVer: String?
            let tsshPass: String?
            let tsshSalt: String?
            let tsshServerCert: String?
            let tsshClientCert: String?
            let tsshClientKey: String?
            let tsshProxyKey: String?
            let tsshClientID: UInt64?
            let tsshServerID: UInt64?
            // SSH fields
            let socks5Address: String?
            // TSSH packet MTU (separate from TUN device mtu)
            let trzszMTU: Int?
            let connectTimeoutSec: Int?
            // Shared
            let dnsServers: [String]?
            let excludedRoutes: [String]?
            let mtu: Int
            let blockQUIC: Bool?
        }

        let goConfig = GoConfig(
            transportType: transportType.rawValue,
            tsshRelayRequired: relayRequired ?? (jumpHostConfig?.tsshRelay != nil ? true : nil),
            tsshHost: tsshServerInfo != nil ? (resolvedHost ?? sshHost) : nil,
            tsshPort: tsshServerInfo?.port,
            tsshMode: tsshServerInfo?.mode,
            tsshServerVer: tsshServerInfo?.serverVersion,
            tsshPass: tsshServerInfo?.pass,
            tsshSalt: tsshServerInfo?.salt,
            tsshServerCert: tsshServerInfo?.serverCert,
            tsshClientCert: tsshServerInfo?.clientCert,
            tsshClientKey: tsshServerInfo?.clientKey,
            tsshProxyKey: tsshServerInfo?.proxyKey,
            tsshClientID: tsshServerInfo?.clientID,
            tsshServerID: tsshServerInfo?.serverID,
            socks5Address: socks5Address,
            trzszMTU: transportMTU ?? trzszMTU,
            connectTimeoutSec: transportType == .tssh ? trzszConnectTimeoutSec : nil,
            dnsServers: dnsServers.isEmpty ? nil : dnsServers,
            excludedRoutes: excludedRoutes.isEmpty ? nil : excludedRoutes,
            mtu: mtu,
            blockQUIC: blockQUIC ? true : nil
        )

        let data = try JSONEncoder().encode(goConfig)
        guard let json = String(data: data, encoding: .utf8) else {
            throw VPNError.configSerializationFailed
        }
        return json
    }
}

extension VPNTunnelConfig {
    init(snapshot: VPNSharedProfileSnapshot) throws {
        guard snapshot.isBackgroundStartable else {
            throw VPNError.credentialAccessFailed(String(localized: "Profile requires a saved password or SSH key before VPN can start.", comment: "VPN error detail: the profile has no background-usable credential"))
        }

        self.profileID = snapshot.id
        self.profileName = snapshot.name
        switch snapshot.transportType {
        case .tssh: self.transportType = .tssh
        case .direct: self.transportType = .direct
        case .ssh: self.transportType = .ssh
        case .tailscale: self.transportType = .tailscale
        }
        self.sshHost = snapshot.host
        self.sshPort = snapshot.port
        self.sshUsername = snapshot.username
        self.sshAuth = snapshot.auth
        let jumpChain = snapshot.jumpChain.map { jumpHost in
            JumpHostTunnelConfig(
                tsshRelay: jumpHost.tsshRelay,
                host: jumpHost.host,
                port: jumpHost.port,
                username: jumpHost.username,
                auth: jumpHost.auth,
                pinnedHostKey: jumpHost.hostKey,
                trustedCAKeys: jumpHost.trustedCAKeys
            )
        }
        self.jumpHostConfig = jumpChain.first
        self.extraJumpHostConfigs = jumpChain.count > 1 ? Array(jumpChain.dropFirst()) : nil
        self.pinnedHostKey = snapshot.hostKey
        self.trustedCAKeys = snapshot.trustedCAKeys
        self.trzszMode = snapshot.trzszMode
        self.trzszUDPPortMin = snapshot.trzszUDPPortMin
        self.trzszUDPPortMax = snapshot.trzszUDPPortMax
        self.trzszMTU = snapshot.trzszMTU
        self.trzszConnectTimeoutSec = snapshot.trzszConnectTimeoutSec.flatMap { (1...120).contains($0) ? $0 : nil }
        self.trzszServerPath = snapshot.trzszServerPath
        self.dnsServers = snapshot.dnsServers
        self.excludedRoutes = snapshot.excludedRoutes
        self.blockQUIC = snapshot.blockQUIC ?? false

        // For TSSH transport, send mtu=0 so the Go bridge auto-calculates
        // TUN MTU from the transport's GetMaxDatagramSize() after connecting.
        // For SSH transport, use 1500 (no datagram overhead).
        if transportType == .tssh {
            self.mtu = 0
        } else {
            self.mtu = 1500
        }
    }
}
