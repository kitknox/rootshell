//
//  SSHTunnelVNCTransport.swift
//  rootshell
//
//  RFBConnection carrying a VNC byte stream over a dedicated SSH
//  connection: SSHConnectionHelper.connect (jump host / CGNAT / .local /
//  host-key prompts included), then a DirectTCPIP channel to the VNC
//  server with a NIOChannelBytePipe on top. Created once per connection
//  attempt by the package's transportProvider; the session calls
//  connect() on it.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOSSH
import RFBProtocol
import RFBTransport
import os

/// SSH direct-tcpip tunnel transport for a VNC session. One instance per
/// connection attempt; owns its SSH client(s) and channel for its lifetime.
actor SSHTunnelVNCTransport: RFBConnection {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "SSHTunnelVNCTransport"
    )

    /// Bound on channel/client close awaits, matching SSHConnectionHelper's
    /// bounded-close rationale (a dead peer can park NIO close futures).
    private static let closeTimeoutSeconds: TimeInterval = 2.0

    /// The DCT encoder only feels backpressure once the channel window fills,
    /// so the 8 MiB default became a standing frame backlog; keep it near TCP's.
    private static let channelWindowSize = 512 * 1024

    private let sshConfig: SSHConfig
    private let vncHost: String
    private let vncPort: UInt16
    private let onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?

    private var client: SSHClient?
    private var jumpClient: SSHClient?
    private var channel: Channel?
    private var pipe: NIOChannelBytePipe?
    private var closed = false
    private var disconnectHandler: (@Sendable (VNCProtocolError) -> Void)?

    /// - Parameters:
    ///   - sshConfig: Fully resolved config (keys resolved, saved passwords
    ///     inlined). Resolution happens on the main actor before the
    ///     provider closure captures this value.
    ///   - vncHost: VNC server host, dialed from the SSH server's side.
    ///   - vncPort: VNC server port.
    ///   - onHostKeyValidation: Routed to the app's host-key prompt UI.
    init(
        sshConfig: SSHConfig,
        vncHost: String,
        vncPort: UInt16,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) {
        self.sshConfig = sshConfig
        self.vncHost = vncHost
        self.vncPort = vncPort
        self.onHostKeyValidation = onHostKeyValidation
    }

    // MARK: - RFBConnection

    func connect() async throws {
        guard !closed else { throw VNCProtocolError.connectionClosed }
        guard client == nil else {
            throw VNCProtocolError.ioError("SSH tunnel transport already connected")
        }

        Self.logger.info("Opening SSH tunnel for VNC to \(self.vncHost):\(self.vncPort)")

        let clients: (client: SSHClient, jumpClient: SSHClient?)
        do {
            clients = try await Self.establishClients(
                config: sshConfig,
                onHostKeyValidation: onHostKeyValidation
            )
        } catch let error as VNCProtocolError {
            throw error
        } catch {
            throw VNCProtocolError.ioError("SSH tunnel failed: \(error.localizedDescription)")
        }

        // close() may have raced the SSH bring-up.
        if closed {
            await Self.closeClients(client: clients.client, jumpClient: clients.jumpClient)
            throw VNCProtocolError.connectionClosed
        }

        do {
            let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let directTCPIP = SSHChannelType.DirectTCPIP(
                targetHost: vncHost,
                targetPort: Int(vncPort),
                originatorAddress: originator
            )

            // The initializer runs on the channel's event loop, which is
            // where NIOChannelBytePipe.install must be called; hand the
            // pipe back through a lock box.
            let pipeBox = OSAllocatedUnfairLock<NIOChannelBytePipe?>(initialState: nil)
            let channel = try await clients.client.createDirectTCPIPChannel(
                using: directTCPIP
            ) { channel in
                do {
                    // Citadel installs its DataToBufferCodec before invoking
                    // this initializer, so this pipeline already carries
                    // plain ByteBuffers. A second SSHChannelData codec would
                    // misinterpret the first inbound RFB protocol banner.
                    let pipe = try NIOChannelBytePipe.install(on: channel)
                    pipeBox.withLock { $0 = pipe }
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            guard let pipe = pipeBox.withLock({ $0 }) else {
                try? await channel.close()
                throw VNCProtocolError.ioError("SSH tunnel pipe was not installed")
            }

            self.client = clients.client
            self.jumpClient = clients.jumpClient
            self.channel = channel
            self.pipe = pipe

            // Out-of-band closure (server drop, SSH teardown while no read
            // is awaited) surfaces through the disconnect handler; a locally
            // requested close() flips `closed` first and is not reported.
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                Task { await self.handleChannelClosed() }
            }
        } catch let error as VNCProtocolError {
            await Self.closeClients(client: clients.client, jumpClient: clients.jumpClient)
            throw error
        } catch {
            await Self.closeClients(client: clients.client, jumpClient: clients.jumpClient)
            throw VNCProtocolError.ioError("VNC channel via SSH failed: \(error.localizedDescription)")
        }

        // close() may also have raced the channel bring-up.
        if closed {
            let channel = self.channel
            let client = self.client
            let jump = self.jumpClient
            self.channel = nil
            self.pipe = nil
            self.client = nil
            self.jumpClient = nil
            if let channel {
                try? await withTimeout(seconds: Self.closeTimeoutSeconds) {
                    try? await channel.close()
                }
            }
            if let client {
                await Self.closeClients(client: client, jumpClient: jump)
            }
            throw VNCProtocolError.connectionClosed
        }

        Self.logger.info("SSH tunnel established to \(self.vncHost):\(self.vncPort)")
    }

    func read(exactly count: Int) async throws -> Data {
        guard !closed, let pipe else { throw VNCProtocolError.connectionClosed }
        do {
            return try await pipe.readExactly(count)
        } catch is NIOChannelBytePipeError {
            throw VNCProtocolError.connectionClosed
        } catch {
            throw closed
                ? VNCProtocolError.connectionClosed
                : VNCProtocolError.ioError("SSH tunnel read failed: \(error.localizedDescription)")
        }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        guard !closed, let pipe else { throw VNCProtocolError.connectionClosed }
        let data: Data?
        do {
            data = try await pipe.read(maxBytes: maxCount)
        } catch {
            throw closed
                ? VNCProtocolError.connectionClosed
                : VNCProtocolError.ioError("SSH tunnel read failed: \(error.localizedDescription)")
        }
        guard let data, !data.isEmpty else {
            throw VNCProtocolError.connectionClosed
        }
        return data
    }

    func send(_ data: Data) async throws {
        guard !closed, let pipe else { throw VNCProtocolError.connectionClosed }
        do {
            try await pipe.write(data)
        } catch {
            throw closed
                ? VNCProtocolError.connectionClosed
                : VNCProtocolError.ioError("SSH tunnel write failed: \(error.localizedDescription)")
        }
    }

    func close() async {
        if closed { return }
        closed = true

        let channel = self.channel
        let client = self.client
        let jump = self.jumpClient
        self.channel = nil
        self.pipe = nil
        self.client = nil
        self.jumpClient = nil
        self.disconnectHandler = nil

        // Channel close releases any parked pipe reader (which then throws
        // connectionClosed via the read paths above).
        if let channel {
            try? await withTimeout(seconds: Self.closeTimeoutSeconds) {
                try? await channel.close()
            }
        }
        if let client {
            await Self.closeClients(client: client, jumpClient: jump)
        }
    }

    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {
        disconnectHandler = handler
    }

    // MARK: - Internal

    /// SSHConnectionHelper is MainActor-bound; hop there for the bring-up
    /// so its non-Sendable closure parameter is passed same-isolation.
    @MainActor
    private static func establishClients(
        config: SSHConfig,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws -> (client: SSHClient, jumpClient: SSHClient?) {
        try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: onHostKeyValidation,
            channelWindowSize: channelWindowSize
        )
    }

    /// Bounded close of the SSH client(s); target first, then the jump.
    private static func closeClients(client: SSHClient, jumpClient: SSHClient?) async {
        try? await withTimeout(seconds: closeTimeoutSeconds) {
            try? await client.close()
        }
        if let jumpClient {
            try? await withTimeout(seconds: closeTimeoutSeconds) {
                try? await jumpClient.close()
            }
        }
    }

    private func handleChannelClosed() {
        guard !closed else { return }
        Self.logger.info("SSH tunnel channel closed by remote")
        disconnectHandler?(.connectionClosed)
    }
}
