//
//  HerdrChannelFactory.swift
//  rootshell
//
//  Opens the long-lived byte channel a herdr control stream rides on, using
//  the connection the gateway pane already holds: an auxiliary exec session
//  on tssh, a second exec channel on a live Citadel client, or a
//  helper-spawned local process on macOS. Mirrors RemoteExecProbe's backend
//  selection, but for a stream that stays open.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
#if canImport(Citadel)
import Citadel
#endif

@MainActor
enum HerdrChannelFactory {

    enum ChannelError: Error, LocalizedError {
        case notConnected
        case unsupportedSession
        case helperUnavailable
        case handoffFailed

        var errorDescription: String? {
            switch self {
            case .notConnected: return "The gateway connection is not established"
            case .unsupportedSession: return "This session type cannot carry a herdr control stream"
            case .helperUnavailable: return "The local helper is not running"
            case .handoffFailed: return "The local helper did not hand over the process"
            }
        }
    }

    /// Whether `owner`'s session can carry a control stream right now.
    /// Capability is a property of the live session, never cached.
    static func canOpen(for owner: Ghostty.TerminalView) -> Bool {
        #if targetEnvironment(macCatalyst)
        if owner.connectionConfig.underlyingSSHConfig == nil { return true }
        #endif
        if TmuxController.gatewayTrzszSession(for: owner.session) != nil { return true }
        #if canImport(Citadel)
        if let citadel = owner.session as? CitadelSSHSession, citadel.client != nil {
            return true
        }
        #endif
        return false
    }

    /// Runs `command` out of band on the host behind `owner` and returns a
    /// bidirectional byte pipe over its stdin and stdout.
    static func open(command: String, on owner: Ghostty.TerminalView) async throws -> AsyncBytePipe {
        #if targetEnvironment(macCatalyst)
        if owner.connectionConfig.underlyingSSHConfig == nil {
            return try await openLocal(command: command, paneToken: owner.uuid.uuidString)
        }
        #endif

        if let trzsz = TmuxController.gatewayTrzszSession(for: owner.session) {
            return try await trzsz.openExecChannel(command)
        }

        #if canImport(Citadel)
        if let citadel = owner.session as? CitadelSSHSession {
            guard let client = citadel.client else { throw ChannelError.notConnected }
            return try await CitadelExecBytePipe.open(client: client, command: command)
        }
        #endif

        throw ChannelError.unsupportedSession
    }

    #if targetEnvironment(macCatalyst)
    private static func openLocal(command: String, paneToken: String) async throws -> AsyncBytePipe {
        guard await HelperConnection.shared.ensureHelperRunning() else {
            throw ChannelError.helperUnavailable
        }
        let spawned = try await HelperConnection.shared.spawnPipedProcess(
            command: command,
            paneToken: paneToken
        )
        // The receiver blocks in select/accept; keep it off the main thread.
        let fd: Int32? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: FDReceiver.receiveFileDescriptor(from: spawned.socketPath))
            }
        }
        guard let fd else {
            await HelperConnection.shared.killPipedProcess(processID: spawned.processID)
            throw ChannelError.handoffFailed
        }
        return LocalPipedProcessPipe(fd: fd, processID: spawned.processID)
    }
    #endif
}

#if targetEnvironment(macCatalyst)
/// Byte pipe over a helper-spawned process; closing also ends the process.
nonisolated final class LocalPipedProcessPipe: AsyncBytePipe, @unchecked Sendable {
    private let pipe: FileDescriptorBytePipe
    private let processID: Int32

    init(fd: Int32, processID: Int32) {
        self.pipe = FileDescriptorBytePipe(fd: fd)
        self.processID = processID
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await pipe.read(maxBytes: maxBytes)
    }

    func write(_ data: Data) async throws {
        try await pipe.write(data)
    }

    func close() async {
        await pipe.close()
        let processID = self.processID
        await HelperConnection.shared.killPipedProcess(processID: processID)
    }
}
#endif
