//
//  KVMLoopbackBridge.swift
//  rootshell
//
//  URLSession can't run over an SSH, tssh or in-app Tailscale tunnel, so a
//  jumped KVM session points URLSession at 127.0.0.1:<port> and this bridge
//  opens one tunnel per accepted connection through the same transport
//  providers Screen Sharing uses.
//

import Foundation
import Network
import os
import RFBProtocol
import RFBTransport
import rootshellVNC

nonisolated final class KVMLoopbackBridge: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "KVM")
    private static let chunkSize = 64 * 1024

    private let provider: VNCTransportProvider
    private let targetHost: String
    private let targetPort: UInt16
    private let queue = DispatchQueue(label: "com.rootshell.kvm.bridge")

    private let lock = NSLock()
    private var listener: NWListener?
    private var pipes: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(provider: @escaping VNCTransportProvider, targetHost: String, targetPort: UInt16) {
        self.provider = provider
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// Binds 127.0.0.1 on an ephemeral port and returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        lock.withLock { self.listener = listener }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let once = KVMOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.fire() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: KVMDError.protocolError("tunnel listener has no port"))
                    }
                case .failed(let error):
                    guard once.fire() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard once.fire() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let (listener, pipes) = lock.withLock {
            stopped = true
            defer { self.pipes.removeAll() }
            return (self.listener, self.pipes.values)
        }
        listener?.cancel()
        pipes.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            Self.logger.error("KVM tunnel refused a non-loopback peer")
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        let task = Task.detached(priority: .userInitiated) { [self] in
            await pipe(connection)
            _ = lock.withLock { pipes.removeValue(forKey: id) }
        }
        let accepted = lock.withLock {
            guard !stopped else { return false }
            pipes[id] = task
            return true
        }
        if !accepted {
            task.cancel()
            connection.cancel()
        }
    }

    private func pipe(_ local: NWConnection) async {
        let remote: any RFBConnection
        do {
            remote = try await provider(targetHost, targetPort)
            try await remote.connect()
        } catch {
            Self.logger.error("KVM tunnel connect failed: \(error.localizedDescription, privacy: .public)")
            local.cancel()
            return
        }
        local.start(queue: queue)

        // Either direction ending tears down both; tunnels don't half-close.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.copyLocalToRemote(local, remote) }
            group.addTask { await Self.copyRemoteToLocal(remote, local) }
            _ = await group.next()
            group.cancelAll()
            local.cancel()
            await remote.close()
        }
    }

    private static func copyLocalToRemote(_ local: NWConnection, _ remote: any RFBConnection) async {
        while !Task.isCancelled {
            guard let data = await receive(from: local) else { return }
            if data.isEmpty { continue }
            do {
                try await remote.send(data)
            } catch {
                return
            }
        }
    }

    private static func copyRemoteToLocal(_ remote: any RFBConnection, _ local: NWConnection) async {
        while !Task.isCancelled {
            guard let data = try? await remote.read(upTo: chunkSize), !data.isEmpty else { return }
            let sent: Bool = await withCheckedContinuation { continuation in
                local.send(content: data, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
            }
            if !sent { return }
        }
    }

    /// Nil at EOF or on error; cancelling the task cancels the connection.
    private static func receive(from connection: NWConnection) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: chunkSize) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(returning: (isComplete || error != nil) ? nil : Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address == IPv6Address("::ffff:127.0.0.1")
        case .name(let name, _): return name == "localhost" || name == "127.0.0.1"
        @unknown default: return false
        }
    }
}

/// Single-shot latch for continuation resumes from repeating callbacks.
nonisolated final class KVMOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.withLock {
            defer { fired = true }
            return !fired
        }
    }
}
