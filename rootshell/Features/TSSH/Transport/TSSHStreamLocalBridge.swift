//
//  TSSHStreamLocalBridge.swift
//  rootshell
//
//  Bridges Go's `StreamLocalCallback` interface to a Swift handler.
//  For each accepted Unix-socket connection delivered by TSSHD's
//  remote-listen mechanism, this bridge wraps the opaque Go channel
//  reference in an ``AsyncBytePipe`` and hands it to `onConnection`
//  (``GPGAgentManager/serve(stream:)`` or
//  ``RemoteAskpassServer/serve(stream:)``) — the same entry points the
//  Citadel transport uses.
//
//  Lifecycle mirrors ``TrzszAgentBridge``: the Go callback method runs
//  on a goroutine, we hop to MainActor to instantiate Swift state, and
//  the per-channel `serve(...)` loop owns the read/write/close calls
//  back through ``TSSHCallGate``.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
#if CHINA_BUILD || targetEnvironment(macCatalyst)
@preconcurrency import TrzszSSH
#else
@preconcurrency import TsshKit
#endif

/// Receives forwarded Unix-socket channels from the TSSHD UDP transport
/// and feeds them to `onConnection`.
///
/// One bridge instance per active forward (per remote socket path).
/// Lifetime is bounded by ``TrzszSession`` — when the session
/// disconnects, the bridge is torn down by calling
/// ``TSSHCallGate/disableStreamLocalForwarding(on:remotePath:)``,
/// which stops the Go-side accept loop and closes any remaining
/// channels.
nonisolated final class TrzszStreamLocalBridge: NSObject,
    IosbridgeStreamLocalCallbackProtocol, @unchecked Sendable {

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszStreamLocalBridge"
    )

    private let onConnection: @MainActor @Sendable (any AsyncBytePipe) async -> Void
    private let transportRef: TSSHTransportRef

    init(
        transportRef: TSSHTransportRef,
        onConnection: @escaping @MainActor @Sendable (any AsyncBytePipe) async -> Void
    ) {
        self.onConnection = onConnection
        self.transportRef = transportRef
        super.init()
    }

    // MARK: - IosbridgeStreamLocalCallbackProtocol

    /// Called per accepted connection from a Go goroutine. Hops to
    /// MainActor, builds an ``AsyncBytePipe`` adapter that drives byte
    /// I/O through ``TSSHCallGate``, and hands it to `onConnection`.
    func onAccept(_ channelRef: Int64) {
        let onConnection = self.onConnection
        let pipe = TrzszStreamLocalPipe(
            channelRef: channelRef,
            transportRef: self.transportRef
        )
        Task { @MainActor in
            await onConnection(pipe)
        }
    }

    func onError(_ message: String?) {
        let msg = message ?? "<no message>"
        Self.logger.warning("streamlocal listener error: \(msg)")
    }
}

// MARK: - AsyncBytePipe adapter

/// Concrete ``AsyncBytePipe`` that pumps bytes through the Go-side
/// channel handle table via ``TSSHCallGate``. The reference is opaque
/// — the Go side resolves it back to a `net.Conn` per call. All
/// reads/writes flow through the gate's serial executor so they don't
/// race with each other or with unrelated transport operations.
private nonisolated final class TrzszStreamLocalPipe: AsyncBytePipe, @unchecked Sendable {

    private let channelRef: Int64
    private let transportRef: TSSHTransportRef

    init(channelRef: Int64, transportRef: TSSHTransportRef) {
        self.channelRef = channelRef
        self.transportRef = transportRef
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await TSSHCallGate.shared.streamLocalRead(
            on: transportRef,
            channelRef: channelRef,
            maxBytes: maxBytes
        )
    }

    func write(_ data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = try await TSSHCallGate.shared.streamLocalWrite(
                on: transportRef,
                channelRef: channelRef,
                data: remaining
            )
            // Zero-progress safety net — without it a buggy peer could
            // wedge the Assuan loop.
            if written <= 0 {
                throw NSError(
                    domain: "TrzszStreamLocalPipe",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "streamlocal write made no progress"]
                )
            }
            remaining = remaining.subdata(in: written..<remaining.count)
        }
    }

    func close() async {
        try? await TSSHCallGate.shared.streamLocalClose(
            on: transportRef,
            channelRef: channelRef
        )
    }
}
