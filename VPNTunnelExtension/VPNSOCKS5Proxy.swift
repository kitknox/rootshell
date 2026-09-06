//
//  VPNSOCKS5Proxy.swift
//  VPNTunnelExtension
//
//  Self-contained SOCKS5 proxy server for the VPN extension.
//  Routes TCP connections through Citadel SSH DirectTCPIP channels.
//

import Foundation
import os.log
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import NIOSSH

enum VPNSOCKS5Error: Error, Equatable {
    case channelCreationTimeout
}

/// Thread-safe one-shot flag for racing channel creation against a timeout.
/// Ensures only the first caller (creation success or timeout) wins; losers no-op.
private nonisolated final class ChannelCreationRace: @unchecked Sendable {
    private var completed = false
    private let lock = NSLock()

    /// Returns true if this call won the race (first to complete).
    func tryComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed { return false }
        completed = true
        return true
    }
}


nonisolated final class VPNSOCKS5DebugMetrics: @unchecked Sendable {
    static let shared = VPNSOCKS5DebugMetrics()

    private let lock = NSLock()
    private var counters: [String: Int64] = [:]
    private var recentEvents: [String] = []
    private var sessionStartedAtMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    private let maxRecentEvents = 120

    // File-based time-series log for full session analysis
    private static let appGroupID = AppIdentifiers.defaultAppGroupID
    static let timeSeriesFilename = "vpn_ssh_timeseries.log"
    private var logFileHandle: FileHandle?
    private var sessionStartTime: UInt64 = 0 // mach_continuous_time reference

    private init() {}

    func resetSession(reason: String) {
        lock.lock()
        counters.removeAll(keepingCapacity: true)
        recentEvents.removeAll(keepingCapacity: true)
        sessionStartedAtMS = Self.nowMS()
        sessionStartTime = Self.uptimeUs()
        appendEventLocked("session-reset \(reason)")
        openLogFileLocked()
        writeLogLineLocked("T+0 session-reset \(reason)")
        lock.unlock()
    }

    func increment(_ key: String, by value: Int64 = 1) {
        lock.lock()
        counters[key, default: 0] += value
        lock.unlock()
    }

    func set(_ key: String, value: Int64) {
        lock.lock()
        counters[key] = value
        lock.unlock()
    }

    func addEvent(_ event: String) {
        lock.lock()
        appendEventLocked(event)
        lock.unlock()
    }

    /// Log a time-series entry to the file log (includes key counters as context).
    func tsLog(_ event: String) {
        lock.lock()
        appendEventLocked(event)
        let elapsed = Self.uptimeUs() - sessionStartTime
        let elapsedMs = elapsed / 1000
        // Snapshot key gauges inline for time-series analysis
        let channels = counters["niossh.multiplexer.channels"] ?? 0
        let pending = counters["niossh.multiplexer.pendingConfirms"] ?? 0
        let active = counters["limiter.activeConnections"] ?? 0
        let tcpWritable = counters["niossh.tcp.isWritable"] ?? -1
        writeLogLineLocked("T+\(elapsedMs)ms ch=\(channels) pend=\(pending) act=\(active) tcpW=\(tcpWritable) \(event)")
        lock.unlock()
    }

    func addErrorEvent(_ prefix: String, error: any Error) {
        let description = String(describing: error)
        if let sshError = error as? NIOSSHError {
            addEvent("\(prefix) \(description) type=\(sshError.type)")
        } else {
            addEvent("\(prefix) \(description)")
        }
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "sessionStartedAtMS": sessionStartedAtMS,
            "snapshotAtMS": Self.nowMS(),
            "counters": counters,
            "recentEvents": recentEvents,
        ]
    }

    /// Read the time-series log file contents (call from main app).
    static func readTimeSeriesLog() -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let fileURL = containerURL.appendingPathComponent(timeSeriesFilename)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Private

    private func appendEventLocked(_ event: String) {
        let entry = "\(Self.nowMS()) \(event)"
        recentEvents.append(entry)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
        }
    }

    private func openLogFileLocked() {
        logFileHandle?.closeFile()
        logFileHandle = nil
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return }
        let fileURL = containerURL.appendingPathComponent(Self.timeSeriesFilename)
        // Truncate on new session
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: fileURL.path)
    }

    private func writeLogLineLocked(_ line: String) {
        guard let handle = logFileHandle,
              let data = (line + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    private static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func uptimeUs() -> UInt64 {
        // mach_continuous_time for monotonic clock, converted to µs
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        return ticks * UInt64(info.numer) / UInt64(info.denom) / 1000
    }
}

/// SOCKS5 proxy server running on localhost in the extension process.
/// Routes connections through an SSH tunnel via Citadel DirectTCPIP channels.
nonisolated final class VPNSOCKS5Proxy: @unchecked Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "SOCKS5Proxy")
    private static let maxConcurrentConnections = 128
    static let channelCreationTimeoutSeconds = 10.0
    private static let localSocketBufferSize = 16 * 1024

    // NIO write watermarks for SOCKS child channels.
    // Controls when channel.isWritable flips, which the VPNChannelBridge
    // checks in read() to apply backpressure on the SSH side. With a 16KB
    // OS socket buffer, NIO flushes 16KB to the kernel immediately; remaining
    // data accumulates in NIO's outbound buffer. When that buffer exceeds
    // socksWriteWatermarkHigh, the channel becomes non-writable, causing
    // sshGlue.read() to defer, which delays SSH WindowAdjust — naturally
    // rate-limiting the server just like OpenSSH does.
    //
    // Default NIO watermarks (32KB low / 64KB high) are too large: with a
    // 16KB OS buffer, NIO stays writable until 64KB of data accumulates,
    // allowing the SSH pipe to saturate before backpressure activates.
    private static let socksWriteWatermarkLow = 16 * 1024
    private static let socksWriteWatermarkHigh = 32 * 1024

    private let clientLock = NSLock()
    private var _sshClient: SSHClient
    private let eventLoopGroup: EventLoopGroup
    private let connectionLimiter: VPNConnectionLimiter
    private var serverChannel: Channel?
    private var boundPort: Int = 0

    /// Current SSH client used for new DirectTCPIP channels.
    /// Lock-protected so it can be swapped during reconnection without
    /// restarting the proxy (which would leave Go without a SOCKS port).
    var currentSSHClient: SSHClient {
        clientLock.withLock { _sshClient }
    }

    /// Hot-swap the SSH client. New SOCKS connections will use the new client;
    /// existing connections continue with the old (dead) client until they fail naturally.
    func updateSSHClient(_ client: SSHClient) {
        clientLock.withLock { _sshClient = client }
        VPNSOCKS5DebugMetrics.shared.addEvent("proxy-ssh-client-swapped")
        Self.logger.info("SOCKS5 proxy SSH client swapped")
    }

    init(sshClient: SSHClient, eventLoopGroup: EventLoopGroup) {
        self._sshClient = sshClient
        self.eventLoopGroup = eventLoopGroup
        self.connectionLimiter = VPNConnectionLimiter(maxConnections: Self.maxConcurrentConnections)
        VPNSOCKS5DebugMetrics.shared.resetSession(reason: "proxy-init")
        VPNSOCKS5DebugMetrics.shared.set("config.maxConcurrentConnections", value: Int64(Self.maxConcurrentConnections))
        VPNSOCKS5DebugMetrics.shared.set("config.localSocketBufferSize", value: Int64(Self.localSocketBufferSize))
    }

    /// Start SOCKS5 proxy on a random available port. Returns the bound port.
    func start(port: Int = 0) async throws -> Int {
        VPNSOCKS5DebugMetrics.shared.increment("proxy.start.attempt")
        let elg = eventLoopGroup
        let limiter = connectionLimiter

        let channel = try await ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(.socketOption(.so_sndbuf), value: Int32(Self.localSocketBufferSize))
            .serverChannelOption(.socketOption(.so_rcvbuf), value: Int32(Self.localSocketBufferSize))
            .childChannelOption(.socketOption(.so_sndbuf), value: Int32(Self.localSocketBufferSize))
            .childChannelOption(.socketOption(.so_rcvbuf), value: Int32(Self.localSocketBufferSize))
            .childChannelOption(.writeBufferWaterMark, value: .init(low: Self.socksWriteWatermarkLow, high: Self.socksWriteWatermarkHigh))
            .childChannelInitializer { [weak self] channel in
                // Read current SSH client at connection time, not at proxy start time.
                // This allows hot-swapping the client during reconnection.
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(
                        VPNSSHError.connectionFailed("SOCKS5 proxy deallocated"))
                }
                let client = self.currentSSHClient
                let handler = makeVPNSOCKS5Handler(sshClient: client, connectionLimiter: limiter)
                return channel.pipeline.addHandler(handler)
            }
            .bind(host: "127.0.0.1", port: port)
            .get()

        self.serverChannel = channel

        if let addr = channel.localAddress, let port = addr.port {
            self.boundPort = port
            VPNSOCKS5DebugMetrics.shared.increment("proxy.start.success")
            VPNSOCKS5DebugMetrics.shared.set("proxy.boundPort", value: Int64(port))
            VPNSOCKS5DebugMetrics.shared.addEvent("proxy-started 127.0.0.1:\(port)")
            Self.logger.info("SOCKS5 proxy started on 127.0.0.1:\(port)")
            return port
        }

        VPNSOCKS5DebugMetrics.shared.increment("proxy.start.no-port")
        throw VPNSSHError.connectionFailed("Failed to bind SOCKS5 proxy")
    }

    /// Stop the SOCKS5 proxy.
    func stop() async {
        VPNSOCKS5DebugMetrics.shared.increment("proxy.stop")
        if let channel = serverChannel {
            try? await channel.close()
            serverChannel = nil
        }
        VPNSOCKS5DebugMetrics.shared.addEvent("proxy-stopped")
        Self.logger.info("SOCKS5 proxy stopped")
    }

    var address: String { "127.0.0.1:\(boundPort)" }
}

// MARK: - SOCKS5 Handler

/// Thread-safe limiter for active SOCKS5 forwarding connections.
nonisolated final class VPNConnectionLimiter: @unchecked Sendable {
    private let maxConnections: Int
    private let lock = NSLock()
    private var activeConnections = 0

    init(maxConnections: Int) {
        self.maxConnections = maxConnections
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < maxConnections else {
            VPNSOCKS5DebugMetrics.shared.increment("limiter.tryAcquire.reject")
            VPNSOCKS5DebugMetrics.shared.set("limiter.activeConnections", value: Int64(activeConnections))
            return false
        }
        activeConnections += 1
        VPNSOCKS5DebugMetrics.shared.increment("limiter.tryAcquire.success")
        VPNSOCKS5DebugMetrics.shared.set("limiter.activeConnections", value: Int64(activeConnections))
        return true
    }

    func release() {
        lock.lock()
        if activeConnections > 0 {
            activeConnections -= 1
        }
        VPNSOCKS5DebugMetrics.shared.increment("limiter.release")
        VPNSOCKS5DebugMetrics.shared.set("limiter.activeConnections", value: Int64(activeConnections))
        lock.unlock()
    }

    func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeConnections
    }
}

/// Tracks a single acquired connection slot and guarantees one-time release.
nonisolated final class VPNConnectionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseHandler: @Sendable () -> Void
    private var released = false

    init(releaseHandler: @escaping @Sendable () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func releaseOnce() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseHandler()
    }
}

/// Metrics delegate that bridges SOCKS5Handler.Delegate to VPNSOCKS5DebugMetrics.
private nonisolated final class VPNMetricsDelegate: SOCKS5Handler.Delegate, Sendable {
    func didReadChannel() {
        VPNSOCKS5DebugMetrics.shared.increment("socks.channelRead")
    }
    func didNegotiateMethod(success: Bool) {
        if success {
            VPNSOCKS5DebugMetrics.shared.increment("socks.methodNegotiation.success")
        } else {
            VPNSOCKS5DebugMetrics.shared.increment("socks.methodNegotiation.invalid")
        }
    }
    func didReceiveConnect(host: String, port: Int) {
        VPNSOCKS5DebugMetrics.shared.increment("socks.connectRequest.received")
        VPNSOCKS5DebugMetrics.shared.addEvent("connect-request \(host):\(port)")
        VPNSOCKS5DebugMetrics.shared.tsLog("SOCKS-CONNECT \(host):\(port)")
    }
    func didActivateForwarding(host: String, port: Int) {
        VPNSOCKS5DebugMetrics.shared.increment("socks.forwarding.activated")
        VPNSOCKS5DebugMetrics.shared.addEvent("forwarding-activated \(host):\(port)")
    }
    func didError(_ message: String) {
        VPNSOCKS5DebugMetrics.shared.increment("socks.errorCaught")
        VPNSOCKS5DebugMetrics.shared.addEvent("socks-error \(message)")
    }
}

/// Creates a SOCKS5Handler configured for the VPN extension with VPN-specific
/// connection handling (VPNChannelBridge, connection limiter, metrics, timeout racing).
func makeVPNSOCKS5Handler(sshClient: SSHClient, connectionLimiter: VPNConnectionLimiter) -> SOCKS5Handler {
    let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "SOCKS5Handler")
    let metricsDelegate = VPNMetricsDelegate()

    return SOCKS5Handler(
        onConnect: { host, port, context, handler in
            guard connectionLimiter.tryAcquire() else {
                let currentCount = connectionLimiter.activeCount()
                VPNSOCKS5DebugMetrics.shared.increment("socks.connectRequest.limitReject")
                VPNSOCKS5DebugMetrics.shared.addEvent("connect-limit-reject \(host):\(port) active=\(currentCount)")
                logger.warning("SOCKS5 connection limit reached (\(currentCount) active), refusing \(host):\(port)")
                handler.sendReply(context: context, status: 0x05)
                return
            }

            let permit = VPNConnectionPermit { [connectionLimiter] in
                connectionLimiter.release()
            }

            let timeout = VPNSOCKS5Proxy.channelCreationTimeoutSeconds

            logger.debug("SOCKS5 CONNECT to \(host):\(port)")

            // ChannelHandlerContext isn't Sendable, but every use below is
            // funnelled back onto its own event loop via `submit`.
            nonisolated(unsafe) let context = context

            Task {
                do {
                    let originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    let (socksGlue, sshGlue) = VPNChannelBridge.matchedPair(onClose: {
                        permit.releaseOnce()
                    })
                    VPNSOCKS5DebugMetrics.shared.increment("bridge.pair.created")

                    let sshChannel: Channel = try await withCheckedThrowingContinuation { continuation in
                        let race = ChannelCreationRace()

                        Task {
                            do {
                                let ch = try await sshClient.createDirectTCPIPChannel(
                                    using: .init(
                                        targetHost: host,
                                        targetPort: port,
                                        originatorAddress: originatorAddress
                                    )
                                ) { channel in
                                    return channel.pipeline.addHandler(sshGlue)
                                }
                                if race.tryComplete() {
                                    continuation.resume(returning: ch)
                                } else {
                                    ch.close(promise: nil)
                                }
                            } catch {
                                if race.tryComplete() {
                                    continuation.resume(throwing: error)
                                }
                            }
                        }

                        Task {
                            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            if race.tryComplete() {
                                VPNSOCKS5DebugMetrics.shared.tsLog("OPEN-TIMEOUT \(host):\(port)")
                                continuation.resume(throwing: VPNSOCKS5Error.channelCreationTimeout)
                            }
                        }
                    }

                    VPNSOCKS5DebugMetrics.shared.increment("ssh.directTCPIP.created")
                    VPNSOCKS5DebugMetrics.shared.tsLog("SSH-CHAN-OK \(host):\(port)")

                    // The inner future is intentionally not awaited: the reply is
                    // sent from the pipeline callback, not this call site.
                    _ = try await context.eventLoop.submit {
                        let ready = context.eventLoop.makePromise(of: Void.self)
                        context.pipeline.addHandler(socksGlue).flatMap {
                            handler.transitionToForwarding()
                            handler.sendReply(context: context, status: 0x00)
                            return context.pipeline.removeHandler(handler)
                        }.whenComplete { result in
                            switch result {
                            case .success:
                                metricsDelegate.didActivateForwarding(host: host, port: port)
                                ready.succeed(())
                            case .failure(let error):
                                VPNSOCKS5DebugMetrics.shared.increment("socks.forwarding.activateFailed")
                                VPNSOCKS5DebugMetrics.shared.addErrorEvent("forwarding-activate-failed", error: error)
                                logger.error("Failed to activate SOCKS5 forwarding: \(error)")
                                permit.releaseOnce()
                                if sshChannel.isActive {
                                    sshChannel.close(promise: nil)
                                }
                                context.close(promise: nil)
                                ready.fail(error)
                            }
                        }
                        return ready.futureResult
                    }.get()

                } catch {
                    let isTimeout = (error as? VPNSOCKS5Error) == .channelCreationTimeout
                    if isTimeout {
                        VPNSOCKS5DebugMetrics.shared.increment("ssh.directTCPIP.timeout")
                        VPNSOCKS5DebugMetrics.shared.addEvent("directtcpip-timeout \(host):\(port)")
                        VPNSOCKS5DebugMetrics.shared.tsLog("SSH-TIMEOUT \(host):\(port)")
                        logger.warning("DirectTCPIP to \(host):\(port) timed out after \(timeout)s")
                    } else {
                        VPNSOCKS5DebugMetrics.shared.increment("ssh.directTCPIP.failed")
                        VPNSOCKS5DebugMetrics.shared.addErrorEvent("directtcpip-failed \(host):\(port)", error: error)
                        VPNSOCKS5DebugMetrics.shared.tsLog("SSH-FAIL \(host):\(port) \(error)")
                        logger.error("DirectTCPIP to \(host):\(port) failed: \(error)")
                    }
                    permit.releaseOnce()
                    try? await context.eventLoop.submit {
                        handler.sendReply(context: context, status: 0x05)
                    }.get()
                }
            }
        },
        delegate: metricsDelegate
    )
}

// MARK: - Channel Bridge (cross-event-loop pair)

/// Bridge that connects an SSH child channel to a SOCKS client channel.
/// These channels live on DIFFERENT event loops (SSH vs SOCKS), so all
/// cross-bridge methods use thread-safe NIO Channel operations or dispatch
/// to the owning event loop.
///
/// Thread safety model:
/// - `lock` protects `channel`, `pendingWrites`, `pendingFlush`, `pendingClose`
///   which may be accessed before `handlerAdded` fires from the partner's thread.
/// - Once `handlerAdded` sets `channel`, partner methods use `Channel` APIs
///   (which are thread-safe in NIO) or dispatch to `channel.eventLoop`.
/// - `context` is only accessed from the owning event loop (never cross-thread).
/// - `partner` is only accessed from the owning event loop (in channelRead etc.).
nonisolated final class VPNChannelBridge: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: VPNChannelBridge?
    private var context: ChannelHandlerContext?  // Only on owning event loop
    private let onClose: (@Sendable () -> Void)?
    private var didSignalClose = false
    private var pendingRead = false
    /// Label for debug logging ("socks" or "ssh")
    let label: String

    // Lock protects state accessed from partner's event loop before handlerAdded
    private let lock = NSLock()
    private var channel: Channel?  // NIO Channel is thread-safe once set
    private var pendingWrites: [NIOAny] = []
    private var pendingFlush = false
    private var pendingClose: PendingClose = .none
    private var didRequestOutputClose = false
    private var didRequestFullClose = false

    private enum PendingClose: Int {
        case none
        case output
        case full
    }

    private init(label: String, onClose: (@Sendable () -> Void)?) {
        self.label = label
        self.onClose = onClose
    }

    static func matchedPair(onClose: (@Sendable () -> Void)? = nil) -> (VPNChannelBridge, VPNChannelBridge) {
        let first = VPNChannelBridge(label: "socks", onClose: onClose)
        let second = VPNChannelBridge(label: "ssh", onClose: onClose)
        first.partner = second
        second.partner = first
        return (first, second)
    }

    // MARK: - Cross-event-loop partner methods

    /// Write data to this bridge's channel. Called from partner's event loop.
    private func partnerWrite(_ data: NIOAny) {
        lock.lock()
        guard let ch = channel else {
            // Not yet in pipeline — queue for replay in handlerAdded
            pendingWrites.append(data)
            VPNSOCKS5DebugMetrics.shared.increment("bridge.pendingWrite.enqueued")
            lock.unlock()
            return
        }
        lock.unlock()
        // Channel.write is thread-safe — dispatches to owning event loop
        ch.write(data, promise: nil)
    }

    /// Flush this bridge's channel. Called from partner's event loop.
    private func partnerFlush() {
        lock.lock()
        guard let ch = channel else {
            pendingFlush = true
            VPNSOCKS5DebugMetrics.shared.increment("bridge.pendingFlush.enqueued")
            lock.unlock()
            return
        }
        lock.unlock()
        ch.flush()
        VPNSOCKS5DebugMetrics.shared.increment("bridge.flush")
    }

    /// Partner's channel became writable — resume our deferred read.
    /// Called from partner's event loop; dispatches to our event loop.
    private func partnerBecameWritable() {
        lock.lock()
        guard let ch = channel else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Dispatch to owning event loop for pendingRead check
        ch.eventLoop.execute { [self] in
            guard self.pendingRead else { return }
            self.pendingRead = false
            VPNSOCKS5DebugMetrics.shared.increment("bridge.read.resumed")
            self.context?.read()
        }
    }

    /// Check if this bridge's channel is writable. Called from partner's event loop.
    private var partnerWritable: Bool {
        lock.lock()
        let ch = channel
        lock.unlock()
        return ch?.isWritable ?? false
    }

    /// Partner received EOF — half-close our output.
    /// Called from partner's event loop; dispatches to ours.
    private func partnerWriteEOF() {
        lock.lock()
        guard !didRequestOutputClose, !didRequestFullClose else {
            lock.unlock()
            return
        }
        didRequestOutputClose = true

        guard let ch = channel else {
            if pendingClose.rawValue < PendingClose.output.rawValue {
                pendingClose = .output
            }
            VPNSOCKS5DebugMetrics.shared.increment("bridge.pendingClose.outputEnqueued")
            lock.unlock()
            return
        }
        lock.unlock()

        ch.eventLoop.execute { [self] in
            guard let ctx = self.context, ctx.channel.isActive else { return }
            VPNSOCKS5DebugMetrics.shared.increment("bridge.close.output")
            ctx.close(mode: .output, promise: nil)
        }
    }

    /// Partner went away — fully close our channel.
    /// Called from partner's event loop; dispatches to ours.
    private func partnerCloseFull() {
        lock.lock()
        guard !didRequestFullClose else {
            lock.unlock()
            return
        }
        didRequestFullClose = true

        guard let ch = channel else {
            pendingClose = .full
            VPNSOCKS5DebugMetrics.shared.increment("bridge.pendingClose.fullEnqueued")
            lock.unlock()
            return
        }
        lock.unlock()

        ch.eventLoop.execute { [self] in
            guard let ctx = self.context, ctx.channel.isActive else { return }
            VPNSOCKS5DebugMetrics.shared.increment("bridge.close.full")
            ctx.close(promise: nil)
        }
    }

    // MARK: - Owning event loop methods

    private func applyPendingCloseIfPossible() {
        guard let context else { return }
        lock.lock()
        let close = pendingClose
        if close != .none { pendingClose = .none }
        lock.unlock()

        switch close {
        case .none:
            break
        case .output:
            guard context.channel.isActive else { return }
            VPNSOCKS5DebugMetrics.shared.increment("bridge.close.output")
            context.close(mode: .output, promise: nil)
        case .full:
            guard context.channel.isActive else { return }
            VPNSOCKS5DebugMetrics.shared.increment("bridge.close.full")
            context.close(promise: nil)
        }
    }

    private func activateIfNeeded() {
        if context?.channel.isWritable == true {
            partner?.partnerBecameWritable()
        }
    }

    private func signalCloseIfNeeded() {
        guard !didSignalClose else { return }
        didSignalClose = true
        onClose?()
    }

    // MARK: - ChannelHandler lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        VPNSOCKS5DebugMetrics.shared.increment("bridge.handlerAdded")
        self.context = context

        // Publish our channel reference under the lock so partner methods
        // switch from queueing to direct Channel calls.
        lock.lock()
        self.channel = context.channel
        let pending = self.pendingWrites
        self.pendingWrites = []
        let shouldFlush = self.pendingFlush
        self.pendingFlush = false
        let close = self.pendingClose
        lock.unlock()

        nonisolated(unsafe) let context = context
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }

        // Drain queued writes from partner (arrived before we had a channel)
        if close != .full, !pending.isEmpty {
            VPNSOCKS5DebugMetrics.shared.increment("bridge.pendingWrite.replayed", by: Int64(pending.count))
            for data in pending {
                context.write(data, promise: nil)
            }
        }
        if close != .full, shouldFlush {
            context.flush()
        }

        // Apply any pending close from partner
        if close != .none {
            lock.lock()
            if close.rawValue > pendingClose.rawValue { pendingClose = close }
            lock.unlock()
            applyPendingCloseIfPossible()
        }

        activateIfNeeded()
    }

    func channelActive(context: ChannelHandlerContext) {
        applyPendingCloseIfPossible()
        activateIfNeeded()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        VPNSOCKS5DebugMetrics.shared.increment("bridge.handlerRemoved")
        signalCloseIfNeeded()
        lock.lock()
        channel = nil
        pendingWrites.removeAll(keepingCapacity: false)
        pendingFlush = false
        pendingClose = .none
        lock.unlock()
        self.context = nil
        self.partner = nil
        self.pendingRead = false
    }

    // MARK: - Inbound channel events (owning event loop only)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        VPNSOCKS5DebugMetrics.shared.increment("bridge.channelRead")
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        VPNSOCKS5DebugMetrics.shared.increment("bridge.channelReadComplete")
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        VPNSOCKS5DebugMetrics.shared.increment("bridge.channelInactive")
        partner?.partnerCloseFull()
        signalCloseIfNeeded()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            VPNSOCKS5DebugMetrics.shared.increment("bridge.inputClosed")
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        VPNSOCKS5DebugMetrics.shared.increment("bridge.errorCaught")
        VPNSOCKS5DebugMetrics.shared.addErrorEvent("bridge-error", error: error)
        partner?.partnerCloseFull()
        signalCloseIfNeeded()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        VPNSOCKS5DebugMetrics.shared.increment("bridge.writabilityChanged")
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
            VPNSOCKS5DebugMetrics.shared.increment("bridge.read.deferred.\(label)")
        }
    }

}
