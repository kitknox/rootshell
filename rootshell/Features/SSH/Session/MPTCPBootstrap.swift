//
//  MPTCPBootstrap.swift
//  rootshell
//
//  Network.framework-backed TCP bootstrap for SSH connections, with optional
//  Multipath TCP. Every SSH TCP connect goes through NIOTSConnectionBootstrap
//  (NWConnection under the hood) so we get VPN on-demand triggering and
//  VPN-scoped path evaluation — necessary for Tailscale `.ts.net` and any
//  other on-demand NetworkExtension VPN where POSIX `connect()` to the
//  CGNAT IPv4 is racy against WireGuard peer wake-up. The "MPTCP" name is
//  retained for historical continuity; the user-facing toggle only controls
//  whether `.withMultipath(.interactive)` is appended.
//

import Foundation
import Network
import NIOCore
import NIOTransportServices
import os.log

enum MPTCPBootstrap {
    private static let logger = Logger(subsystem: "com.rootshell", category: "MPTCPBootstrap")

    /// Dedicated high-priority event loop group for interactive SSH terminal
    /// sessions so keystrokes and echoes run on P-cores at `.userInteractive`
    /// QoS and never queue behind bulk SFTP, Git, or background SSH traffic.
    private static let interactiveEventLoopGroup: NIOTSEventLoopGroup = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let loopCount = max(2, min(cores, 4))
        return NIOTSEventLoopGroup(loopCount: loopCount, defaultQoS: .userInteractive)
    }()

    /// Shared event loop group for non-interactive SSH connections (SFTP, Git,
    /// headless probes, Mosh/Trzsz spawners).
    /// Must be kept alive for the lifetime of any channels created on it.
    ///
    /// `loopCount` is bumped above the default of 1: NIOSSH's
    /// `NIOSSHPrivateKeyProtocol.signature(for:)` is a synchronous API,
    /// and the YubiKey / Apple-FIDO2 bridges in
    /// `YubiKeyNIOSSHPrivateKey` and `AppleFIDO2NIOSSHPrivateKey`
    /// translate that into a `DispatchSemaphore.wait()` while the
    /// hardware-token / Face-ID prompt is on screen. With a
    /// single-loop group, that wait stalls the event loop for the
    /// duration of the prompt, freezing every other live SSH session
    /// (Citadel keep-alives, in-flight channel reads, the lot).
    /// Spreading sessions across multiple loops bounds the blast
    /// radius: only sessions that happen to land on the blocked loop
    /// stall, others continue to drive their channels normally.
    private static let tsEventLoopGroup: NIOTSEventLoopGroup = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let loopCount = max(2, min(cores, 4))
        return NIOTSEventLoopGroup(loopCount: loopCount, defaultQoS: .userInitiated)
    }()

    static var isEnabled: Bool {
        SettingsStore.shared.value(Settings.Roam.multipathTCP)
    }

    private static var shouldForceIPv4: Bool {
        SettingsStore.shared.value(Settings.Connections.forceIPv4)
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        host.contains(":")
    }

    /// Create a pre-connected channel suitable for passing to SSHClient.connect(on:).
    /// No SSH handlers are added — Citadel adds those itself.
    /// autoRead stays off until Citadel's `connect(on:)` installs them; an earlier read
    /// would drop the server banner and hang the handshake (#535).
    ///
    /// Callers are responsible for pre-resolving CGNAT/`.local` hostnames to an
    /// IPv4 literal before invoking this function (see CitadelSSHSession and
    /// SSHConnectionHelper). Passing an IP literal disables NWConnection's
    /// Happy Eyeballs v2, which is what we want — Mosh's UDP hole-puncher binds
    /// its local socket to the same address family as the SSH session, so a
    /// silent IPv6-ULA preference here would regress Mosh-over-Tailscale.
    static func connectPlainChannel(
        host: String,
        port: Int,
        timeout: TimeAmount = .seconds(30),
        interactive: Bool = false
    ) async throws -> Channel {
        #if !CHINA_BUILD
        if let channel = try await TailnetDialer.channel(host: host, port: port, timeout: timeout) {
            logger.info("tailnet connect \(host):\(port)")
            return channel
        }
        #endif
        let group = interactive ? interactiveEventLoopGroup : tsEventLoopGroup
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        if interactive {
            // Prevent Darwin TCP from stretching/delaying ACKs during
            // interactive request/response exchanges (TCP_SENDMOREACKS).
            tcpOptions.disableAckStretching = true
        }
        var bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(timeout)
            .tcpOptions(tcpOptions)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(NIOTSChannelOptions.minimumIncompleteReceiveLength, value: 1)
            .channelOption(NIOTSChannelOptions.maximumReceiveLength, value: 65536)
        if interactive {
            bootstrap = bootstrap.withQoS(.userInteractive)
        }
        let mode: String
        if isEnabled {
            bootstrap = bootstrap.withMultipath(.interactive)
            mode = interactive ? "niots+multipath+interactive" : "niots+multipath"
        } else {
            mode = interactive ? "niots+interactive" : "niots"
        }
        let forceIPv4 = shouldForceIPv4 && !isIPv6Literal(host)
        if forceIPv4 || interactive {
            bootstrap = bootstrap.configureNWParameters { parameters in
                if interactive {
                    // Marks packets for low-latency interactive scheduling
                    // (WMM AC_VI / Darwin FQ-CoDel interactive queue / DSCP).
                    parameters.serviceClass = .interactiveVideo
                }
                if forceIPv4,
                   let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ipOptions.version = .v4
                }
            }
        }
        logger.info("\(mode) connect \(host):\(port) timeout=\(timeout.nanoseconds / 1_000_000_000)s")
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            #if !CHINA_BUILD
            throw TailnetDialer.explain(error, host: host)
            #else
            throw error
            #endif
        }
        let local = channel.localAddress?.description ?? "?"
        let remote = channel.remoteAddress?.description ?? "?"
        logger.info("\(mode) connected local=\(local) remote=\(remote)")
        return channel
    }
}
