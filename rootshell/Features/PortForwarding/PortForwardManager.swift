//
//  PortForwardManager.swift
//  rootshell
//
//  Manages active SSH port forwards for a session
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import os.log

// MARK: - ByteCountingHandler

/// Handler that counts bytes passing through and reports via callback.
/// Designed for TCP channels that receive ByteBuffer data.
/// Place at the beginning of the pipeline to count raw bytes.
/// Thread safety: All state is immutable after init; accessed only on NIO event loop.
nonisolated final class ByteCountingHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let forwardID: UUID
    private let onBytesRead: @Sendable (UUID, Int) -> Void
    private let onBytesWritten: @Sendable (UUID, Int) -> Void

    init(
        forwardID: UUID,
        onBytesRead: @escaping @Sendable (UUID, Int) -> Void,
        onBytesWritten: @escaping @Sendable (UUID, Int) -> Void
    ) {
        self.forwardID = forwardID
        self.onBytesRead = onBytesRead
        self.onBytesWritten = onBytesWritten
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onBytesRead(forwardID, buffer.readableBytes)
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        onBytesWritten(forwardID, buffer.readableBytes)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }
}

// MARK: - LocalForwardListener

/// TCP server that listens on a local port and forwards connections through SSH.
final class LocalForwardListener: @unchecked Sendable {
    private var serverChannel: Channel?

    /// Start listening on the specified host and port.
    /// Returns the actual bound port (useful if bindPort was 0).
    ///
    /// Uses `MultiThreadedEventLoopGroup.singleton` for the ServerBootstrap because
    /// ServerBootstrap requires SelectableEventLoop (incompatible with NIOTSEventLoop
    /// used by MPTCP connections).
    ///
    /// `reuseAddress: false` makes the bind fail while anything else listens on
    /// the port, including the wildcard address.
    func start(
        bindHost: String,
        bindPort: Int,
        reuseAddress: Bool = true,
        onConnection: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Int {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: reuseAddress ? 1 : 0)
            .childChannelInitializer { childChannel in
                onConnection(childChannel)
            }
            .bind(host: bindHost, port: bindPort)
            .get()

        serverChannel = channel

        guard let localAddress = channel.localAddress, let port = localAddress.port else {
            throw PortForwardError.bindFailed(port: bindPort, underlying: PortForwardError.invalidConfiguration("Could not determine bound port"))
        }

        return port
    }

    /// Stop the listener and close all connections.
    func stop() async {
        if let channel = serverChannel {
            try? await channel.close()
            serverChannel = nil
        }
    }
}

// MARK: - PortForwardManager

/// Manages active port forwards for an SSH session
@MainActor
final class PortForwardManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "PortForwardManager")

    private let client: SSHClient
    private let config: PortForwardConfig

    /// Active local forwarding tasks (bind port -> task)
    private var localForwardTasks: [Int: Task<Void, Never>] = [:]

    /// Active remote forwarding tasks (bind port -> task)
    private var remoteForwardTasks: [Int: Task<Void, Never>] = [:]

    /// Active local forward listeners (bind port -> listener)
    private var localForwardListeners: [Int: LocalForwardListener] = [:]

    /// Active SOCKS5 proxy servers (bind port -> server)
    private var socksProxies: [Int: SOCKS5ProxyServer] = [:]

    /// Active SOCKS5 proxy tasks (bind port -> task)
    private var socksProxyTasks: [Int: Task<Void, Never>] = [:]

    /// Status of each forward
    private var forwardStatus: [UUID: PortForwardStatus] = [:]

    /// Local listeners started from the remote-port status bar. Unlike
    /// `localForwardTasks`, these are keyed by their own id: several of them
    /// bind port 0 at once, so the configured bind port is not unique.
    private var adHocForwards: [UUID: AdHocForward] = [:]
    private var adHocForwardByRemotePort: [UInt16: UUID] = [:]
    /// One bind per remote port at a time; a second caller shares it.
    private var adHocStarts: [UInt16: Task<AdHocForwardHandle, Error>] = [:]
    /// Bumped by stopAllForwards so a bind finishing after teardown is dropped.
    private var adHocGeneration = 0

    private struct AdHocForward {
        let handle: AdHocForwardHandle
        let listener: LocalForwardListener
    }

    /// Callback for forwarding errors (non-fatal, reported to UI)
    var onForwardError: ((PortForwardConfig.PortForward, Error) -> Void)?

    /// Callback for forwarding status updates
    var onForwardStatusChange: ((PortForwardConfig.PortForward, PortForwardStatus) -> Void)?

    /// Callback for bytes received (forwardID, byteCount)
    var onBytesReceived: (@Sendable (UUID, Int) -> Void)?

    /// Callback for bytes sent (forwardID, byteCount)
    var onBytesSent: (@Sendable (UUID, Int) -> Void)?

    /// Callback for connection opened on a forward
    var onConnectionOpened: ((UUID) -> Void)?

    /// Callback for connection closed on a forward
    var onConnectionClosed: ((UUID) -> Void)?

    /// Callback when SSH connection appears dead (consecutive channel creation failures)
    var onConnectionDead: (() -> Void)?

    /// Count of consecutive SSH errors indicating connection death
    private var consecutiveSSHErrors: Int = 0

    /// Threshold for declaring connection dead
    private static let sshErrorThreshold = 3

    init(client: SSHClient, config: PortForwardConfig) {
        self.client = client
        self.config = config
    }

    /// Start all configured port forwards
    func startAllForwards() async {
        Self.logger.info("Starting \(self.config.forwards.count) port forwards")

        for forward in config.localForwards {
            await startLocalForward(forward)
        }

        for forward in config.remoteForwards {
            await startRemoteForward(forward)
        }

        for forward in config.dynamicForwards {
            await startDynamicForward(forward)
        }
    }

    /// Stop all port forwards and cleanup
    func stopAllForwards() async {
        Self.logger.info("Stopping all port forwards")

        // Cancel local forward tasks (this will trigger their cleanup)
        for (port, task) in localForwardTasks {
            Self.logger.debug("Cancelling local forward on port \(port)")
            task.cancel()
        }
        localForwardTasks.removeAll()

        // Stop local forward listeners explicitly - await completion
        let listeners = localForwardListeners
        localForwardListeners.removeAll()
        for (port, listener) in listeners {
            Self.logger.debug("Stopping local forward listener on port \(port)")
            await listener.stop()
        }

        // Cancel remote forward tasks
        for (port, task) in remoteForwardTasks {
            Self.logger.debug("Cancelling remote forward on port \(port)")
            task.cancel()
        }
        remoteForwardTasks.removeAll()

        // Stop SOCKS5 proxies
        for (port, task) in socksProxyTasks {
            Self.logger.debug("Cancelling SOCKS5 proxy on port \(port)")
            task.cancel()
        }
        socksProxyTasks.removeAll()

        let proxies = socksProxies
        socksProxies.removeAll()
        for (port, proxy) in proxies {
            Self.logger.debug("Stopping SOCKS5 proxy on port \(port)")
            await proxy.stop()
        }

        // Release all SOCKS port claims
        for forward in config.dynamicForwards {
            SOCKSPortRegistry.shared.releaseAll(forwardID: forward.id)
        }

        // Stop status-bar forwards too. Sessions call stopAllForwards during
        // teardown, so a closed tab never leaves a loopback listener behind.
        adHocGeneration += 1
        let adHoc = adHocForwards
        adHocForwards.removeAll()
        adHocForwardByRemotePort.removeAll()
        for forward in adHoc.values {
            await forward.listener.stop()
        }

        // Update all statuses to stopped
        for forward in config.forwards {
            updateStatus(forward, .stopped)
        }
    }

    // MARK: - Ad Hoc Forwarding (status bar)

    /// Starts a loopback listener for one remote port. The caller owns the
    /// handle and must pass it to `stopAdHocLocalForward` when done.
    func startAdHocLocalForward(
        remoteHost: String,
        remotePort: UInt16,
        preferredLocalPort: UInt16?
    ) async throws -> AdHocForwardHandle {
        if let existing = adHocForward(forRemotePort: remotePort) { return existing }
        if let pending = adHocStarts[remotePort] { return try await pending.value }
        // Capture the generation before the task can run: a task queued
        // before stopAllForwards must not insert a listener after teardown.
        let generation = adHocGeneration
        let task = Task {
            try await self.bindAdHocLocalForward(
                remoteHost: remoteHost, remotePort: remotePort, preferredLocalPort: preferredLocalPort,
                generation: generation
            )
        }
        adHocStarts[remotePort] = task
        defer {
            if adHocStarts[remotePort] == task { adHocStarts.removeValue(forKey: remotePort) }
        }
        return try await task.value
    }

    func adHocForward(forRemotePort remotePort: UInt16) -> AdHocForwardHandle? {
        adHocForwardByRemotePort[remotePort].flatMap { adHocForwards[$0]?.handle }
    }

    private func bindAdHocLocalForward(
        remoteHost: String,
        remotePort: UInt16,
        preferredLocalPort: UInt16?,
        generation: Int
    ) async throws -> AdHocForwardHandle {
        let forwardID = UUID()
        let listener = LocalForwardListener()
        let client = self.client
        let onBytesReceived = self.onBytesReceived
        let onBytesSent = self.onBytesSent
        let onConnectionOpened = self.onConnectionOpened
        let onConnectionClosed = self.onConnectionClosed
        let onSSHChannelError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in self?.handleSSHChannelError(error) }
        }
        let onSSHChannelSuccess: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.handleSSHChannelSuccess() }
        }

        let bind: (Int) async throws -> Int = { bindPort in
            try await listener.start(bindHost: "127.0.0.1", bindPort: bindPort, reuseAddress: false) { inboundChannel in
                Self.handleLocalConnection(
                    inboundChannel: inboundChannel,
                    targetHost: remoteHost,
                    targetPort: Int(remotePort),
                    client: client,
                    forwardID: forwardID,
                    onBytesReceived: onBytesReceived,
                    onBytesSent: onBytesSent,
                    onConnectionOpened: onConnectionOpened,
                    onConnectionClosed: onConnectionClosed,
                    onSSHChannelError: onSSHChannelError,
                    onSSHChannelSuccess: onSSHChannelSuccess
                )
            }
        }

        // The preferred local port is a convenience, not a requirement: one a
        // local server already uses falls back to an ephemeral port.
        let preferred = preferredLocalPort.flatMap { LoopbackPort.isFree($0) ? Int($0) : nil } ?? 0
        let boundPort: Int
        do {
            boundPort = try await bind(preferred)
        } catch {
            guard preferred > 0, (error as? IOError)?.errnoCode == EADDRINUSE else { throw error }
            Self.logger.info("Preferred local port \(preferred) unavailable, using an ephemeral port")
            boundPort = try await bind(0)
        }
        guard generation == adHocGeneration else {
            await listener.stop()
            throw PortForwardError.sessionClosed
        }

        let handle = AdHocForwardHandle(
            id: forwardID,
            remotePort: remotePort,
            localPort: UInt16(boundPort)
        )
        adHocForwards[forwardID] = AdHocForward(handle: handle, listener: listener)
        adHocForwardByRemotePort[remotePort] = forwardID
        Self.logger.info("Ad hoc forward 127.0.0.1:\(boundPort) -> \(remoteHost):\(remotePort)")
        return handle
    }

    func stopAdHocLocalForward(_ handle: AdHocForwardHandle) async {
        guard let forward = adHocForwards.removeValue(forKey: handle.id) else { return }
        if adHocForwardByRemotePort[forward.handle.remotePort] == handle.id {
            adHocForwardByRemotePort.removeValue(forKey: forward.handle.remotePort)
        }
        await forward.listener.stop()
        Self.logger.info("Stopped ad hoc forward for remote port \(handle.remotePort)")
    }

    // MARK: - Local Forwarding (-L)

    /// Start a local port forward listener
    private func startLocalForward(_ forward: PortForwardConfig.PortForward) async {
        Self.logger.info("Starting local forward: \(forward.displayString)")
        updateStatus(forward, .pending)

        let bindHost = forward.bindAddress.isEmpty ? "127.0.0.1" : forward.bindAddress
        let targetHost = forward.targetHost
        let targetPort = forward.targetPort
        let client = self.client

        let task = Task { [weak self] in
            guard let self = self else { return }

            do {
                // Create local TCP listener
                let listener = LocalForwardListener()

                await MainActor.run {
                    self.localForwardListeners[forward.bindPort] = listener
                }

                // Capture callbacks for use in connection handler
                let onBytesReceived = await MainActor.run { self.onBytesReceived }
                let onBytesSent = await MainActor.run { self.onBytesSent }
                let onConnectionOpened = await MainActor.run { self.onConnectionOpened }
                let onConnectionClosed = await MainActor.run { self.onConnectionClosed }
                let forwardID = forward.id

                // Create callbacks for SSH error tracking
                let onSSHChannelError: @Sendable (Error) -> Void = { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.handleSSHChannelError(error)
                    }
                }

                let onSSHChannelSuccess: @Sendable () -> Void = { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleSSHChannelSuccess()
                    }
                }

                // Start listening and handle each incoming connection
                let boundPort = try await listener.start(
                    bindHost: bindHost,
                    bindPort: forward.bindPort
                ) { [weak self] inboundChannel in
                    guard self != nil else {
                        return inboundChannel.eventLoop.makeFailedFuture(PortForwardError.sessionClosed)
                    }

                    return Self.handleLocalConnection(
                        inboundChannel: inboundChannel,
                        targetHost: targetHost,
                        targetPort: targetPort,
                        client: client,
                        forwardID: forwardID,
                        onBytesReceived: onBytesReceived,
                        onBytesSent: onBytesSent,
                        onConnectionOpened: onConnectionOpened,
                        onConnectionClosed: onConnectionClosed,
                        onSSHChannelError: onSSHChannelError,
                        onSSHChannelSuccess: onSSHChannelSuccess
                    )
                }

                Self.logger.info("Local forward listening on \(bindHost):\(boundPort) -> \(targetHost):\(targetPort)")

                await MainActor.run {
                    self.updateStatus(forward, .active)
                }

                // Keep the task alive until cancelled - the listener runs independently
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                }

            } catch is CancellationError {
                Self.logger.debug("Local forward cancelled for \(forward.displayString)")
            } catch let error as NIOCore.IOError where error.errnoCode == EADDRINUSE {
                Self.logger.error("Port \(forward.bindPort) already in use")
                await MainActor.run {
                    self.updateStatus(forward, .failed("Port \(forward.bindPort) already in use"))
                    self.onForwardError?(forward, PortForwardError.portInUse(port: forward.bindPort))
                }
            } catch {
                Self.logger.error("Local forward failed for \(forward.displayString): \(error.localizedDescription)")
                await MainActor.run {
                    self.updateStatus(forward, .failed(error.localizedDescription))
                    self.onForwardError?(forward, error)
                }
            }

            // Cleanup listener on exit
            if let listener = await MainActor.run(body: { self.localForwardListeners.removeValue(forKey: forward.bindPort) }) {
                await listener.stop()
            }
        }

        localForwardTasks[forward.bindPort] = task
    }

    /// Handle a single incoming connection on a local forward listener.
    ///
    /// This method addresses a race condition where NIO could read TCP data before handlers
    /// are installed. The fix involves:
    /// 1. ChannelBridge pair created synchronously before any async work
    /// 2. Handlers installed on inbound channel synchronously via NIO futures
    /// 3. SSH channel handler installed in Citadel's initialize callback
    /// 4. Future only completes after SSH channel is ready, so NIO's autoRead
    ///    doesn't trigger until both handlers are linked
    private nonisolated static func handleLocalConnection(
        inboundChannel: Channel,
        targetHost: String,
        targetPort: Int,
        client: SSHClient,
        forwardID: UUID,
        onBytesReceived: (@Sendable (UUID, Int) -> Void)?,
        onBytesSent: (@Sendable (UUID, Int) -> Void)?,
        onConnectionOpened: ((UUID) -> Void)?,
        onConnectionClosed: ((UUID) -> Void)?,
        onSSHChannelError: (@Sendable (Error) -> Void)?,
        onSSHChannelSuccess: (@Sendable () -> Void)?
    ) -> EventLoopFuture<Void> {
        let eventLoop = inboundChannel.eventLoop

        // Build originator address for the DirectTCPIP request
        let originatorAddress: SocketAddress
        if let remoteAddress = inboundChannel.remoteAddress {
            originatorAddress = remoteAddress
        } else {
            do {
                originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }

        let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: targetHost,
            targetPort: targetPort,
            originatorAddress: originatorAddress
        )

        // Notify connection opened
        if let onConnectionOpened = onConnectionOpened {
            Task { @MainActor in onConnectionOpened(forwardID) }
        }

        // Create glue handler pair SYNCHRONOUSLY before any async work.
        // This ensures handlers are ready to be installed immediately.
        // Use ChannelBridge (not GlueHandler) because the TCP channel
        // (from MultiThreadedEventLoopGroup.singleton) and SSH channel
        // (SSHChildChannel on the connection's event loop) may be on
        // different event loops. ChannelBridge handles cross-EL bridging safely.
        let (localGlue, sshGlue) = ChannelBridge.matchedPair()

        // Install handlers on inbound channel SYNCHRONOUSLY using NIO futures.
        // This ensures handlers are in place before the future completes.
        // NIO waits for childChannelInitializer's future before activating the channel,
        // so autoRead won't trigger until our future completes (after SSH channel is ready).
        let inboundHandlersFuture: EventLoopFuture<Void>

        if let onBytesReceived = onBytesReceived, let onBytesSent = onBytesSent {
            let byteCounter = ByteCountingHandler(
                forwardID: forwardID,
                onBytesRead: onBytesReceived,
                onBytesWritten: onBytesSent
            )
            inboundHandlersFuture = inboundChannel.pipeline.addHandlers([byteCounter, localGlue])
        } else {
            inboundHandlersFuture = inboundChannel.pipeline.addHandler(localGlue)
        }

        // Set up close handler to notify when connection ends
        inboundChannel.closeFuture.whenComplete { _ in
            if let onConnectionClosed = onConnectionClosed {
                Task { @MainActor in onConnectionClosed(forwardID) }
            }
        }

        // Chain: install inbound handlers -> create SSH channel -> enable reads
        return inboundHandlersFuture.flatMap { _ -> EventLoopFuture<Void> in
            let promise = eventLoop.makePromise(of: Void.self)

            Task {
                do {
                    // Create SSH channel with sshGlue installed in Citadel's callback.
                    // This ensures the SSH side handler is installed synchronously during
                    // channel creation, before the channel becomes active.
                    _ = try await client.createDirectTCPIPChannel(
                        using: directTCPIP
                    ) { channel in
                        // Install sshGlue synchronously in Citadel's callback
                        return channel.pipeline.addHandler(sshGlue)
                    }

                    // Both handlers are now installed and linked.
                    // When this promise succeeds, NIO will activate the channel and
                    // autoRead will trigger the first read automatically.
                    logger.debug("Local forward connection established: local -> \(targetHost):\(targetPort)")
                    onSSHChannelSuccess?()
                    promise.succeed(())

                } catch {
                    logger.error("Failed to create DirectTCPIP channel: \(error.localizedDescription)")
                    onSSHChannelError?(error)
                    inboundChannel.close(promise: nil)
                    promise.fail(error)
                }
            }

            return promise.futureResult
        }
    }

    // MARK: - Dynamic Forwarding (-D)

    /// Start a dynamic SOCKS5 proxy forward
    private func startDynamicForward(_ forward: PortForwardConfig.PortForward) async {
        Self.logger.info("Starting dynamic forward: \(forward.displayString)")
        updateStatus(forward, .pending)

        // Check port registry - another session may already own this port
        guard SOCKSPortRegistry.shared.claim(port: forward.bindPort, forwardID: forward.id) else {
            Self.logger.info("SOCKS5 port \(forward.bindPort) handled by another session")
            updateStatus(forward, .active)
            return
        }

        let client = self.client

        let task = Task { [weak self] in
            guard let self = self else { return }

            do {
                let server = SOCKS5ProxyServer(sshClient: client)

                await MainActor.run {
                    self.socksProxies[forward.bindPort] = server
                }

                let bindHost = forward.bindAddress.isEmpty ? "127.0.0.1" : forward.bindAddress
                let boundPort = try await server.start(host: bindHost, port: forward.bindPort)
                let boundPortLog = boundPort
                Self.logger.info("SOCKS5 proxy listening on \(bindHost):\(boundPortLog)")

                await MainActor.run {
                    self.updateStatus(forward, .active)
                }

                // Keep the task alive until cancelled
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                }

            } catch is CancellationError {
                Self.logger.debug("Dynamic forward cancelled for \(forward.displayString)")
            } catch let error as NIOCore.IOError where error.errnoCode == EADDRINUSE {
                Self.logger.error("Port \(forward.bindPort) already in use")
                await MainActor.run {
                    self.updateStatus(forward, .failed("Port \(forward.bindPort) already in use"))
                    self.onForwardError?(forward, PortForwardError.portInUse(port: forward.bindPort))
                }
            } catch {
                Self.logger.error("Dynamic forward failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.updateStatus(forward, .failed(error.localizedDescription))
                    self.onForwardError?(forward, error)
                }
            }

            // Cleanup
            if let server = await MainActor.run(body: { self.socksProxies.removeValue(forKey: forward.bindPort) }) {
                await server.stop()
            }
            await MainActor.run {
                SOCKSPortRegistry.shared.release(port: forward.bindPort, forwardID: forward.id)
            }
        }

        socksProxyTasks[forward.bindPort] = task
    }

    // MARK: - Remote Forwarding (-R)

    /// Start a remote port forward
    private func startRemoteForward(_ forward: PortForwardConfig.PortForward) async {
        Self.logger.info("Starting remote forward: \(forward.displayString)")
        updateStatus(forward, .pending)

        let task = Task { [weak self, client] in
            guard let self = self else { return }

            // Check if client is still connected before starting
            guard client.isConnected else {
                Self.logger.warning("Cannot start remote forward - SSH client not connected")
                await MainActor.run {
                    self.updateStatus(forward, .failed("SSH connection lost"))
                    self.onConnectionDead?()
                }
                return
            }

            do {
                // Use Citadel's high-level remote port forward API
                let bindHost = forward.bindAddress.isEmpty ? "0.0.0.0" : forward.bindAddress

                try await client.runRemotePortForward(
                    host: bindHost,
                    port: forward.bindPort,
                    forwardingTo: forward.targetHost,
                    port: forward.targetPort
                ) { portForward in
                    Self.logger.info("Remote forward established on \(portForward.host):\(portForward.boundPort) -> \(forward.targetHost):\(forward.targetPort)")

                    await MainActor.run {
                        self.updateStatus(forward, .active)
                    }
                }

                // If we get here, the forward completed normally
                Self.logger.info("Remote forward ended for \(forward.displayString)")

            } catch {
                if Task.isCancelled {
                    Self.logger.debug("Remote forward cancelled for \(forward.displayString)")
                } else {
                    Self.logger.error("Remote forward failed for \(forward.displayString): \(error.localizedDescription)")
                    await MainActor.run {
                        self.updateStatus(forward, .failed(error.localizedDescription))
                        self.onForwardError?(forward, error)
                    }
                }
            }
        }

        remoteForwardTasks[forward.bindPort] = task
    }

    // MARK: - Status Management

    private func updateStatus(_ forward: PortForwardConfig.PortForward, _ status: PortForwardStatus) {
        forwardStatus[forward.id] = status
        onForwardStatusChange?(forward, status)
    }

    /// Get the current status of a forward
    func status(for forward: PortForwardConfig.PortForward) -> PortForwardStatus {
        forwardStatus[forward.id] ?? .pending
    }

    // MARK: - SSH Connection Health Tracking

    /// Handle SSH channel creation error - track consecutive failures to detect connection death
    private func handleSSHChannelError(_ error: Error) {
        // OPEN_FAILURE is the server answering, so the connection is alive. Its text contains
        // "channel", which the patterns below would otherwise count: any local app hitting a closed
        // target port three times would tear the tunnel down.
        if let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected {
            Self.logger.debug("SSH channel open refused by server: \(error.localizedDescription)")
            consecutiveSSHErrors = 0
            return
        }

        // Check if this error indicates the SSH connection is dead
        let errorString = String(describing: error).lowercased()

        // Common patterns indicating SSH connection death:
        // - Channel closed/inactive
        // - Connection reset
        // - Broken pipe
        // - EOF
        let connectionDeathPatterns = [
            "channel",
            "closed",
            "inactive",
            "reset",
            "broken",
            "eof",
            "connection",
            "disconnected"
        ]

        let looksLikeConnectionDeath = connectionDeathPatterns.contains { errorString.contains($0) }

        if looksLikeConnectionDeath {
            consecutiveSSHErrors += 1
            Self.logger.warning("SSH channel error (\(self.consecutiveSSHErrors)/\(Self.sshErrorThreshold)): \(error.localizedDescription)")

            if consecutiveSSHErrors >= Self.sshErrorThreshold {
                Self.logger.error("SSH connection appears dead after \(self.consecutiveSSHErrors) consecutive failures")
                onConnectionDead?()
            }
        } else {
            // Non-fatal error (e.g., target refused connection) - reset counter
            Self.logger.debug("Non-fatal SSH channel error: \(error.localizedDescription)")
            consecutiveSSHErrors = 0
        }
    }

    /// Handle successful SSH channel creation - reset error counter
    private func handleSSHChannelSuccess() {
        if consecutiveSSHErrors > 0 {
            Self.logger.debug("SSH channel succeeded, resetting error counter from \(self.consecutiveSSHErrors)")
            consecutiveSSHErrors = 0
        }
    }
}

// MARK: - AdHocForwarding

extension PortForwardManager: AdHocForwarding {}
