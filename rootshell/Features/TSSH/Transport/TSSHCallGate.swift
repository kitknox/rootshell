//
//  TSSHCallGate.swift
//  rootshell
//
//  Single chokepoint for every Swift→Go call into the gomobile-bound
//  `iosbridge` package (Swift module `TrzszSSH`). All `Iosbridge*` symbols
//  must be invoked from inside this file.
//
//  ## Architecture
//
//  Two queues, one source of truth:
//
//    * `registry` — `OSAllocatedUnfairLock`-protected ref→object map.
//      Registry mutations are atomic and accessible from both the actor's
//      executor and from `nonisolated` emergency paths.
//
//    * `workerQueue` — concurrent `DispatchQueue` on which the blocking
//      gomobile calls run (Connect / NewSession / AttachSession /
//      Shell / RequestPty / setenv / enableAgentForwarding / Write /
//      WindowChange / Close / etc.). Per-transport ordering is enforced by
//      Go's per-transport mutex; cross-transport calls run in parallel,
//      so a slow Connect on one transport does not block writes/resizes
//      on every other transport.
//
//  Every gomobile call is initiated from a method on `TSSHCallGate.shared`.
//  No other Swift code in the project may import `TrzszSSH` or reference
//  `Iosbridge*` symbols, with the four documented exceptions for the
//  reverse-binding bridges that *implement* gomobile protocols (they make
//  no Swift→Go calls):
//    - TSSHCallGate.swift            (this file)
//    - TrzszAgentBridge.swift
//    - TrzszGoCallbackBridges.swift
//    - TrzszGoForwardCallbackBridge.swift
//
//  Callers hold opaque `Sendable` ref structs (`TSSHTransportRef`,
//  `TSSHSessionRef`, `TSSHForwarderRef`); the underlying `Iosbridge*` objects
//  never escape the gate.
//
//  ## Liveness: emergency teardown
//
//  Three `nonisolated` methods bypass the actor entirely so a wedged write
//  can never prevent forceful tear-down:
//
//    * `emergencyAbandon(_:)` — dispatches `Transport.Abandon()` directly
//      onto the worker queue. Abandoning a transport whose write is blocked
//      causes the wedged write to error out.
//    * `emergencyClosePortForwarder(_:)` — same for `PortForwarder.Close()`.
//    * `discardSessionImmediate(_:)` — drops a session ref from the
//      registry without invoking any Go call.
//
//  The graceful `close(_ ref:)` methods leave the registry entry in place
//  until the Go call returns (`defer`-based removal). If close wedges, the
//  defer never runs, the entry stays, and a fallback `emergencyAbandon`
//  scheduled by the caller can still locate and tear down the transport.
//

import Foundation
import os
import OSLog
@preconcurrency import TrzszSSH

// MARK: - Sendable handles

nonisolated struct TSSHTransportRef: Sendable, Hashable {
    fileprivate let id: UUID
}

nonisolated struct TSSHSessionRef: Sendable, Hashable {
    fileprivate let id: UUID
}

nonisolated struct TSSHForwarderRef: Sendable, Hashable {
    fileprivate let id: UUID
}

// MARK: - Errors

enum TSSHCallGateError: LocalizedError {
    case unknownTransport
    case unknownSession
    case unknownForwarder
    case configCreationFailed
    case forwarderCreationFailed(String)
    case connectFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTransport:
            return "Unknown TSSH transport (handle is invalid or already closed)"
        case .unknownSession:
            return "Unknown TSSH session (handle is invalid or already closed)"
        case .unknownForwarder:
            return "Unknown TSSH port forwarder (handle is invalid or already closed)"
        case .configCreationFailed:
            return "Failed to create TSSH config struct"
        case .forwarderCreationFailed(let msg):
            return "Failed to create port forwarder: \(msg)"
        case .connectFailed(let msg):
            return "TSSH connect failed: \(msg)"
        }
    }
}

// MARK: - Parameter structs

struct TSSHTransportParams: Sendable {
    let host: String
    let port: Int
    let serverVersion: String
    let mode: String           // "KCP" or "QUIC"
    let clientID: Int64
    let serverID: Int64
    let mtu: Int               // 0 = use Go-side default
    let proxyKeyHex: String?
    let kcpPassHex: String?
    let kcpSaltHex: String?
    let serverCertHex: String?
    let clientCertHex: String?
    let clientKeyHex: String?
    let debugLabel: String
}

/// Point-in-time transport statistics mirrored from the gomobile
/// `TransportStats` snapshot. Counters are cumulative since connect;
/// durations are milliseconds. QUIC byte/packet counts are protocol-level,
/// KCP counts are UDP wire-level. `retransSegs` is process-global across
/// every KCP session (`retransIsGlobal`).
nonisolated struct TSSHTransportStatsSnapshot: Sendable {
    let mode: String
    let srttMs: Int64
    let rttVarMs: Int64
    let minRttMs: Int64
    let latestRttMs: Int64
    let rtoMs: Int64
    let bytesSent: Int64
    let bytesReceived: Int64
    let packetsSent: Int64
    let packetsReceived: Int64
    let bytesLost: Int64
    let packetsLost: Int64
    let retransSegs: Int64
    let hasMinRtt: Bool
    let hasRto: Bool
    let hasLoss: Bool
    let retransIsGlobal: Bool
}

struct TSSHForwardParams: Sendable {
    let forwardID: String      // UUID string
    let direction: String      // "local" | "remote" | "dynamic"
    let bindAddress: String
    let bindPort: Int
    let targetHost: String
    let targetPort: Int
    let recoverRemoteListener: Bool
}

// MARK: - Registry storage
//
// A class so it can hold non-Sendable Iosbridge handles. Marked
// `@unchecked Sendable` because every access is protected by the gate's
// `OSAllocatedUnfairLock` — no concurrent mutation is possible.

private nonisolated final class TSSHRegistryStorage: @unchecked Sendable {
    var transports: [TSSHTransportRef: IosbridgeTransport] = [:]
    var relayParents: [TSSHTransportRef: TSSHTransportRef] = [:]
    var sessions:   [TSSHSessionRef:   IosbridgeTransportSession] = [:]
    var forwarders: [TSSHForwarderRef: IosbridgePortForwarder] = [:]
}

// MARK: - Gate

actor TSSHCallGate {
    static let shared = TSSHCallGate()

    /// Concurrent queue on which all blocking gomobile calls execute.
    /// Per-transport ordering is provided by Go's per-transport mutex; a
    /// slow Connect on one transport runs in parallel with writes/resizes
    /// on every other transport.
    private nonisolated let workerQueue = DispatchQueue(
        label: "com.kk2.rootshell.tssh.gate.worker",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Sole source of truth for ref→object mappings. Accessed from both
    /// the actor and from `nonisolated` emergency-teardown paths.
    private nonisolated let registry = OSAllocatedUnfairLock<TSSHRegistryStorage>(
        initialState: TSSHRegistryStorage()
    )

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TSSHCallGate"
    )

    private init() {}

    // MARK: - Worker dispatch helpers

    private nonisolated func runOnWorker<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            workerQueue.async {
                do {
                    let value = try work()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated func runOnWorker(
        _ work: @Sendable @escaping () -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workerQueue.async {
                work()
                continuation.resume()
            }
        }
    }

    // MARK: - Debug logger (fast)

    /// Registers (or clears) the global Go-side debug logger. Pass nil to disable.
    func setDebugLogger(_ bridge: TrzszGoDebugLoggerBridge?) {
        IosbridgeSetDebugLogger(bridge)
    }

    // MARK: - Transport lifecycle

    func connect(_ params: TSSHTransportParams, via proxyRef: TSSHTransportRef? = nil) async throws -> TSSHTransportRef {
        guard let config = IosbridgeNewTransportConfig() else {
            throw TSSHCallGateError.configCreationFailed
        }
        // IPv6 addresses must be wrapped in brackets for Go's net.JoinHostPort.
        config.host = params.host.contains(":") && !params.host.hasPrefix("[")
            ? "[\(params.host)]"
            : params.host
        config.port = params.port
        config.serverVersion = params.serverVersion
        config.mode = params.mode
        config.clientID = params.clientID
        config.serverID = params.serverID
        if params.mtu > 0 {
            config.mtu = params.mtu
        }
        config.debugLabel = params.debugLabel

        if let pass = params.kcpPassHex, let salt = params.kcpSaltHex {
            config.setKcpCredentials(pass, salt: salt)
        }
        if let serverCert = params.serverCertHex,
           let clientCert = params.clientCertHex,
           let clientKey  = params.clientKeyHex {
            config.setQuicCredentials(serverCert, clientCert: clientCert, clientKey: clientKey)
        }
        if let proxyKey = params.proxyKeyHex {
            config.proxyKey = proxyKey
        }

        // The actual handshake runs on the worker queue, releasing the
        // actor for other gate methods (writes/resizes/health polls on
        // existing transports proceed concurrently).
        nonisolated(unsafe) let proxy: IosbridgeTransport? = proxyRef.flatMap { ref in
            registry.withLock { $0.transports[ref] }
        }
        if proxyRef != nil && proxy == nil { throw TSSHCallGateError.unknownTransport }
        nonisolated(unsafe) let connectConfig = config
        let transport: IosbridgeTransport = try await runOnWorker {
            var connectError: NSError?
            let connected: IosbridgeTransport?
            if let proxy {
                connected = IosbridgeConnectTransportViaProxy(connectConfig, proxy, &connectError)
            } else {
                connected = IosbridgeConnectTransport(connectConfig, &connectError)
            }
            guard let transport = connected else {
                throw TSSHCallGateError.connectFailed(
                    connectError?.localizedDescription ?? "unknown error"
                )
            }
            return transport
        }

        let ref = TSSHTransportRef(id: UUID())
        registry.withLock {
            $0.transports[ref] = transport
            $0.relayParents[ref] = proxyRef
        }
        if Task.isCancelled {
            emergencyAbandon(ref)
            throw CancellationError()
        }
        return ref
    }

    func close(_ ref: TSSHTransportRef) async throws {
        // Look up but do NOT remove yet. If transport.close() wedges, we
        // never reach the defer below — and any fallback emergencyAbandon
        // can still find the entry and force-tear-down. The defer fires on
        // both successful return and thrown error.
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return }

        nonisolated(unsafe) let t = transport
        let registry = self.registry
        defer {
            registry.withLock { _ = $0.transports.removeValue(forKey: ref) }
        }
        do { try await runOnWorker { try t.close() } }
        catch {
            if let parent = registry.withLock({ $0.relayParents.removeValue(forKey: ref) }) {
                emergencyAbandon(parent)
            }
            throw error
        }
        if let parent = registry.withLock({ $0.relayParents.removeValue(forKey: ref) }) {
            try await close(parent)
        }
    }

    func effectiveRelayMTU(_ ref: TSSHTransportRef, requested: Int, mode: String) async throws -> Int {
        guard let transport = registry.withLock({ $0.transports[ref] }) else { throw TSSHCallGateError.unknownTransport }
        nonisolated(unsafe) let t = transport
        return try await runOnWorker {
            var result = 0
            try t.effectiveRelayMTU(requested, mode: mode, ret0_: &result)
            return result
        }
    }

    func lastActiveTimeMs(_ ref: TSSHTransportRef) -> Int64 {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return 0 }
        // getLastActiveTime() is a fast atomic-stamp read on Go side.
        return transport.getLastActiveTime()
    }

    /// Snapshot of live transport statistics, or nil when the transport is
    /// gone/closed. Never throws — a stale ref (e.g. after a reconnect
    /// replaced the transport) just yields nil. The gomobile call is cheap
    /// (atomic reads) but still runs on the worker queue per gate policy.
    func transportStats(_ ref: TSSHTransportRef) async -> TSSHTransportStatsSnapshot? {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return nil }
        nonisolated(unsafe) let t = transport
        return try? await runOnWorker { () -> TSSHTransportStatsSnapshot? in
            guard let s = t.getStats() else { return nil }
            return TSSHTransportStatsSnapshot(
                mode: s.mode,
                srttMs: s.srttMs,
                rttVarMs: s.rttVarMs,
                minRttMs: s.minRttMs,
                latestRttMs: s.latestRttMs,
                rtoMs: s.rtoMs,
                bytesSent: s.bytesSent,
                bytesReceived: s.bytesReceived,
                packetsSent: s.packetsSent,
                packetsReceived: s.packetsReceived,
                bytesLost: s.bytesLost,
                packetsLost: s.packetsLost,
                retransSegs: s.retransSegs,
                hasMinRtt: s.hasMinRtt,
                hasRto: s.hasRto,
                hasLoss: s.hasLoss,
                retransIsGlobal: s.retransIsGlobal
            )
        } ?? nil
    }

    func setKeepPendingInput(on ref: TSSHTransportRef, keep: Bool) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        try await runOnWorker { try t.setKeepPendingInput(keep) }
    }

    func setKeepPendingOutput(on ref: TSSHTransportRef, keep: Bool) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        try await runOnWorker { try t.setKeepPendingOutput(keep) }
    }

    func setDiscardNotifier(
        on ref: TSSHTransportRef,
        notifier: TrzszGoDiscardBridge
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        await runOnWorker { t.setDiscardNotifier(notifier) }
    }

    func setHealthNotifier(
        on ref: TSSHTransportRef,
        notifier: TrzszGoHealthBridge
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        await runOnWorker { t.setHealthNotifier(notifier) }
    }

    func enableAgentForwarding(
        on ref: TSSHTransportRef,
        callback: TrzszAgentBridge
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        try await runOnWorker { try t.enableAgentForwarding(callback) }
    }

    // MARK: - Stream-local (Unix socket) forwarding

    /// Ask the TSSHD server to listen on the given remote Unix socket
    /// path and forward every accepted connection back to us via
    /// `callback.onAccept`. Each accepted connection then drives
    /// byte I/O through ``streamLocalRead`` / ``streamLocalWrite`` /
    /// ``streamLocalClose`` using the int64 channel reference handed
    /// to the bridge.
    func enableStreamLocalForwarding(
        on ref: TSSHTransportRef,
        remotePath: String,
        callback: TrzszStreamLocalBridge
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        try await runOnWorker {
            try t.enableStreamLocalForwarding(remotePath, callback: callback)
        }
    }

    /// Tear down a previously enabled stream-local forward.
    func disableStreamLocalForwarding(
        on ref: TSSHTransportRef,
        remotePath: String
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return }
        nonisolated(unsafe) let t = transport
        try await runOnWorker { try t.disableStreamLocalForwarding(remotePath) }
    }

    /// Open a direct TCP connection from the tsshd server to host:port.
    /// Returns an int64 channel handle registered in the same Go-side
    /// table as stream-local channels, so byte I/O flows through
    /// ``streamLocalRead`` / ``streamLocalWrite`` / ``streamLocalClose``.
    /// The blocking Go dial runs on the worker queue.
    func dialTCP(
        on ref: TSSHTransportRef,
        host: String,
        port: Int
    ) async throws -> Int64 {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        return try await runOnWorker {
            var channelRef: Int64 = 0
            try t.dialTCP(host, port: port, ret0_: &channelRef)
            return channelRef
        }
    }

    /// Read up to `maxBytes` from a stream-local channel. Returns nil
    /// on clean EOF; throws on transport error.
    func streamLocalRead(
        on ref: TSSHTransportRef,
        channelRef: Int64,
        maxBytes: Int
    ) async throws -> Data? {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        let clamped = Int32(min(maxBytes, Int(Int32.max)))
        return try await runOnWorker {
            let data = try t.streamLocalRead(channelRef, maxBytes: clamped)
            // The Go side signals clean EOF as nil-data + nil-error;
            // gomobile maps that to an empty Data. Surface as nil so
            // the AsyncBytePipe contract reads cleanly.
            return data.isEmpty ? nil : data
        }
    }

    /// Write `data` to a stream-local channel. Returns the number of
    /// bytes the Go side accepted on this call — callers should loop
    /// until everything is written.
    func streamLocalWrite(
        on ref: TSSHTransportRef,
        channelRef: Int64,
        data: Data
    ) async throws -> Int {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        return try await runOnWorker {
            var written: Int32 = 0
            try t.streamLocalWrite(channelRef, data: data, ret0_: &written)
            return Int(written)
        }
    }

    /// Run a one-shot command on the remote and return its combined
    /// stdout+stderr bytes. Used by the GPG forwarding setup to
    /// probe `id -u` / `$HOME` so socket-path placeholders can be
    /// substituted before sshd's `bind(2)` (which does no expansion).
    func runRemoteCommand(
        on ref: TSSHTransportRef,
        command: String
    ) async throws -> Data {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        return try await runOnWorker {
            try t.runCommand(command)
        }
    }

    /// Close a stream-local channel; idempotent.
    func streamLocalClose(
        on ref: TSSHTransportRef,
        channelRef: Int64
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return }
        nonisolated(unsafe) let t = transport
        try await runOnWorker { try t.streamLocalClose(channelRef) }
    }

    // MARK: - Auxiliary exec channels

    /// Start `command` in an auxiliary non-PTY session on the same tsshd
    /// and return its exec channel handle. Unlike the primary session
    /// there can be many, and they never carry the discard machinery.
    func openExec(
        on ref: TSSHTransportRef,
        command: String
    ) async throws -> Int64 {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        return try await runOnWorker {
            var channelRef: Int64 = 0
            try t.openExec(command, ret0_: &channelRef)
            return channelRef
        }
    }

    /// Read up to `maxBytes` of the command's stdout. Blocks on the
    /// concurrent worker until data arrives; nil on clean EOF.
    func execRead(
        on ref: TSSHTransportRef,
        channelRef: Int64,
        maxBytes: Int
    ) async throws -> Data? {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        let clamped = min(maxBytes, Int(Int32.max))
        return try await runOnWorker {
            let data = try t.execRead(channelRef, maxBytes: clamped)
            return data.isEmpty ? nil : data
        }
    }

    /// Write to the command's stdin; returns the bytes accepted.
    func execWrite(
        on ref: TSSHTransportRef,
        channelRef: Int64,
        data: Data
    ) async throws -> Int {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        return try await runOnWorker {
            var written: Int32 = 0
            try t.execWrite(channelRef, data: data, ret0_: &written)
            return Int(written)
        }
    }

    /// Deliver EOF on the command's stdin while stdout stays readable.
    func execCloseStdin(
        on ref: TSSHTransportRef,
        channelRef: Int64
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return }
        nonisolated(unsafe) let t = transport
        try await runOnWorker { try t.execCloseStdin(channelRef) }
    }

    /// Exit code once the command finished, -1 while it runs.
    func execExitCode(
        on ref: TSSHTransportRef,
        channelRef: Int64
    ) async -> Int {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return -1 }
        nonisolated(unsafe) let t = transport
        return (try? await runOnWorker { t.execExitCode(channelRef) }) ?? -1
    }

    /// Tear down an exec channel; idempotent.
    func execClose(
        on ref: TSSHTransportRef,
        channelRef: Int64
    ) async throws {
        let transport = registry.withLock { $0.transports[ref] }
        guard let transport else { return }
        nonisolated(unsafe) let t = transport
        try await runOnWorker { try t.execClose(channelRef) }
    }

    // MARK: - Session lifecycle

    func newSession(
        on transportRef: TSSHTransportRef,
        output: TrzszGoOutputBridge
    ) async throws -> TSSHSessionRef {
        let transport = registry.withLock { $0.transports[transportRef] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        let session: IosbridgeTransportSession = try await runOnWorker {
            let s = try t.newSession()
            s.setOutputCallback(output)
            return s
        }
        let ref = TSSHSessionRef(id: UUID())
        registry.withLock { $0.sessions[ref] = session }
        return ref
    }

    func attachSession(
        on transportRef: TSSHTransportRef,
        sessionID: Int64,
        term: String,
        rows: Int,
        cols: Int,
        output: TrzszGoOutputBridge
    ) async throws -> (ref: TSSHSessionRef, sessionID: Int64) {
        let transport = registry.withLock { $0.transports[transportRef] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        let attached: (session: IosbridgeTransportSession, id: Int64) =
            try await runOnWorker {
                let s = try t.attachSession(sessionID, term: term, rows: rows, cols: cols)
                s.setOutputCallback(output)
                return (s, s.getID())
            }
        let ref = TSSHSessionRef(id: UUID())
        registry.withLock { $0.sessions[ref] = attached.session }
        return (ref, attached.id)
    }

    /// Sets env vars, optionally requests agent forwarding, requests a PTY,
    /// and starts a shell or exec command. Replaces five separate gomobile
    /// calls with one gate-owned operation. Returns the server-assigned
    /// session ID.
    func openShellOrCommand(
        on sessionRef: TSSHSessionRef,
        lang: String?,
        languages: String?,
        agentForwarding: Bool,
        term: String,
        rows: Int,
        cols: Int,
        execCommand: String?,
        paneToken: String? = nil
    ) async throws -> Int64 {
        let session = registry.withLock { $0.sessions[sessionRef] }
        guard let session else {
            throw TSSHCallGateError.unknownSession
        }
        nonisolated(unsafe) let s = session
        return try await runOnWorker { () -> Int64 in
            // LANG / LANGUAGE — server may reject env requests; log but continue.
            if let lang {
                do {
                    try s.setenv("LANG", value: lang)
                } catch {
                    Self.logger.warning("Failed to set LANG: \(error.localizedDescription)")
                }
            }
            if let languages {
                do {
                    try s.setenv("LANGUAGE", value: languages)
                } catch {
                    Self.logger.warning("Failed to set LANGUAGE: \(error.localizedDescription)")
                }
            }
            // Identify the client to the remote host; same silent-drop caveat as LANG.
            for envVar in TerminalIdentity.forwardedVariables(paneToken: paneToken) {
                do {
                    try s.setenv(envVar.name, value: envVar.value)
                } catch {
                    Self.logger.warning("Failed to set \(envVar.name): \(error.localizedDescription)")
                }
            }
            if agentForwarding {
                try s.requestAgentForwarding()
            }
            try s.requestPty(term, rows: rows, cols: cols)
            if let execCommand {
                try s.startCommand(execCommand)
            } else {
                try s.shell()
            }
            return s.getID()
        }
    }

    // MARK: - Session I/O

    func write(_ sessionRef: TSSHSessionRef, _ data: Data) async throws {
        let session = registry.withLock { $0.sessions[sessionRef] }
        guard let session else {
            throw TSSHCallGateError.unknownSession
        }
        nonisolated(unsafe) let s = session
        try await runOnWorker { try s.write(data) }
    }

    func resize(_ sessionRef: TSSHSessionRef, rows: Int, cols: Int) async throws {
        let session = registry.withLock { $0.sessions[sessionRef] }
        guard let session else {
            throw TSSHCallGateError.unknownSession
        }
        nonisolated(unsafe) let s = session
        try await runOnWorker { try s.windowChange(rows, cols: cols) }
    }

    func close(_ sessionRef: TSSHSessionRef) async throws {
        let session = registry.withLock { $0.sessions[sessionRef] }
        guard let session else { return }

        nonisolated(unsafe) let s = session
        let registry = self.registry
        defer {
            registry.withLock { _ = $0.sessions.removeValue(forKey: sessionRef) }
        }
        try await runOnWorker { try s.close() }
    }

    /// Drops a session ref without invoking Close on Go (the underlying
    /// session is presumed already gone — e.g., transport was abandoned or
    /// has been replaced via Attach). Use Close otherwise.
    func discardSession(_ sessionRef: TSSHSessionRef) {
        registry.withLock { _ = $0.sessions.removeValue(forKey: sessionRef) }
    }

    // MARK: - Port forwarding

    func newPortForwarder(
        on transportRef: TSSHTransportRef,
        callback: TrzszGoForwardCallbackBridge
    ) async throws -> TSSHForwarderRef {
        let transport = registry.withLock { $0.transports[transportRef] }
        guard let transport else {
            throw TSSHCallGateError.unknownTransport
        }
        nonisolated(unsafe) let t = transport
        let forwarder: IosbridgePortForwarder = try await runOnWorker {
            var error: NSError?
            guard let f = IosbridgeNewPortForwarder(t, callback, &error) else {
                throw TSSHCallGateError.forwarderCreationFailed(
                    error?.localizedDescription ?? "unknown error"
                )
            }
            return f
        }
        let ref = TSSHForwarderRef(id: UUID())
        registry.withLock { $0.forwarders[ref] = forwarder }
        return ref
    }

    func startForward(
        on forwarderRef: TSSHForwarderRef,
        _ params: TSSHForwardParams
    ) async throws {
        let forwarder = registry.withLock { $0.forwarders[forwarderRef] }
        guard let forwarder else {
            throw TSSHCallGateError.unknownForwarder
        }
        nonisolated(unsafe) let f = forwarder
        try await runOnWorker {
            guard let goConfig = IosbridgeNewForwardConfig() else {
                throw TSSHCallGateError.configCreationFailed
            }
            goConfig.forwardID   = params.forwardID
            goConfig.direction   = params.direction
            goConfig.bindAddress = params.bindAddress
            goConfig.bindPort    = params.bindPort
            goConfig.targetHost  = params.targetHost
            goConfig.targetPort  = params.targetPort
            goConfig.recoverRemoteListener = params.recoverRemoteListener
            try f.startForward(goConfig)
        }
    }

    func close(_ forwarderRef: TSSHForwarderRef) async {
        let forwarder = registry.withLock { $0.forwarders[forwarderRef] }
        guard let forwarder else { return }

        nonisolated(unsafe) let f = forwarder
        let registry = self.registry
        defer {
            registry.withLock { _ = $0.forwarders.removeValue(forKey: forwarderRef) }
        }
        await runOnWorker { f.close() }
    }

    // MARK: - Diagnostics

    var transportCount: Int { registry.withLock { $0.transports.count } }
    var sessionCount:   Int { registry.withLock { $0.sessions.count } }
    var forwarderCount: Int { registry.withLock { $0.forwarders.count } }

    // MARK: - Emergency teardown (nonisolated, bypasses the actor)
    //
    // These three methods are the documented liveness escape hatch. They
    // are `nonisolated` so they can run while the actor is busy or while
    // the worker queue is hosting a wedged Go call. Each calls a single
    // teardown gomobile function on the worker queue without going through
    // the actor.
    //
    // Calling `Abandon()` on a transport whose `Write()` is currently
    // blocked causes the blocked write to error out (transport state goes
    // dead), which resumes the gate's queued continuation and unwedges the
    // worker thread for any subsequent queued items. `PortForwarder.Close()`
    // is documented as safe to call independently of any in-flight
    // transport call.
    //
    // The graceful `close(_:)` methods leave the registry entry populated
    // until their Go call returns (defer-based removal). If close wedges,
    // its defer never runs, the entry stays, and the methods below can
    // still locate the object.

    /// Forcefully abandons a transport, bypassing the actor.
    /// Idempotent. Safe to call concurrently with a wedged transport call.
    nonisolated func emergencyAbandon(_ ref: TSSHTransportRef) {
        let transports: [IosbridgeTransport] = registry.withLock { storage in
            var result: [IosbridgeTransport] = []
            var current: TSSHTransportRef? = ref
            while let id = current {
                if let transport = storage.transports.removeValue(forKey: id) { result.append(transport) }
                current = storage.relayParents.removeValue(forKey: id)
            }
            return result
        }
        workerQueue.async {
            for transport in transports { transport.abandon() }
        }
    }

    /// Forcefully closes a port forwarder, bypassing the actor.
    /// Idempotent.
    nonisolated func emergencyClosePortForwarder(_ ref: TSSHForwarderRef) {
        let forwarder = registry.withLock { $0.forwarders.removeValue(forKey: ref) }
        guard let forwarder else { return }
        Self.logger.info("emergencyClosePortForwarder: dispatching Go Close on worker queue")
        workerQueue.async {
            forwarder.close()
        }
    }

    /// Drops a session ref from the registry without invoking any Go call.
    /// Used by emergency teardown so subsequent gate-side `write`/`resize`
    /// lookups fail fast after the underlying transport has been abandoned.
    nonisolated func discardSessionImmediate(_ ref: TSSHSessionRef) {
        registry.withLock { _ = $0.sessions.removeValue(forKey: ref) }
    }
}
