//
//  TSSHGoCallbackBridges.swift
//  rootshell
//
//  Reverse-binding bridges for the Go→Swift callback direction. Go goroutines
//  call into these classes synchronously via gomobile; the bridges hop the
//  payload onto the appropriate sink (`OutputSink`, deferred-event queue, or
//  `ResumeDebugLogger`).
//
//  These bridges DO NOT make Swift→Go calls. They are exempt from the
//  `TSSHCallGate` chokepoint by design — see TSSHCallGate.swift for the
//  invariant.
//

import Foundation
import os
import OSLog
#if CHINA_BUILD || targetEnvironment(macCatalyst)
@preconcurrency import TrzszSSH
#else
@preconcurrency import TsshKit
#endif

#if targetEnvironment(macCatalyst)
import IOKit
#endif

/// Bridges Go's `TSSHOutputCallback` interface to a `TrzszGoTransport`.
/// Calls land on background goroutine threads; the transport's nonisolated
/// hooks own the dispatch back onto Swift's main actor / output sinks.
nonisolated final class TrzszGoOutputBridge: NSObject, IosbridgeTSSHOutputCallbackProtocol, @unchecked Sendable {
    private enum Phase: Sendable {
        case live
        /// The transport replaced this session on purpose; its closing output and exit must not reach the pane.
        case retired
        /// A replacement session: an end before its ready marker fails the swap rather than the pane.
        case probation(MainChannelMarkerScanner, MainChannelReadiness)
    }

    private weak var transport: TrzszGoTransport?
    private let phase: OSAllocatedUnfairLock<Phase>

    init(transport: TrzszGoTransport, probation: (marker: Data, readiness: MainChannelReadiness)? = nil) {
        self.transport = transport
        self.phase = OSAllocatedUnfairLock(initialState: probation.map {
            .probation(MainChannelMarkerScanner(marker: $0.marker), $0.readiness)
        } ?? .live)
        super.init()
    }

    func retire() {
        endPhase()?.resolve(false)
    }

    /// Retires the bridge, returning the readiness it was still on probation for.
    private func endPhase() -> MainChannelReadiness? {
        phase.withLock { phase in
            defer { phase = .retired }
            if case .probation(_, let readiness) = phase { return readiness }
            return nil
        }
    }

    /// The transport for an end event, or nil when the event is dropped.
    private var transportForEnd: TrzszGoTransport? {
        let isLive = phase.withLock { phase in
            if case .live = phase { return true }
            return false
        }
        guard isLive else {
            retire()
            return nil
        }
        return transport
    }

    func onOutput(_ data: Data?) {
        guard let data else { return }
        let (passes, attached) = phase.withLock { phase -> (Bool, MainChannelReadiness?) in
            switch phase {
            case .retired:
                return (false, nil)
            case .live:
                return (true, nil)
            case .probation(var scanner, let readiness):
                guard scanner.scan(data) else {
                    phase = .probation(scanner, readiness)
                    return (true, nil)
                }
                phase = .live
                return (true, readiness)
            }
        }
        if passes, let transport { transport.emitOutputFromGoCallback(data) }
        attached?.resolve(true)
    }

    func onError(_ message: String?) {
        guard let message, let transport = transportForEnd else { return }
        transport.deferGoCallbackEvent(.error(message))
    }

    func onExit(_ exitCode: Int) {
        guard let transport = transportForEnd else { return }
        transport.deferGoCallbackEvent(.exit(exitCode))
    }

    func onClose() {
        guard let transport = transportForEnd else { return }
        transport.deferGoCallbackEvent(.close)
    }
}

/// One-shot result of a replacement session's probation; the first resolve wins.
nonisolated final class MainChannelReadiness: Sendable {
    private struct State: Sendable {
        var result: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func resolve(_ ready: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.result == nil else { return nil }
            state.result = ready
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: ready)
    }

    /// Waits for the result, resolving false after `timeout`.
    func wait(timeout: Duration) async -> Bool {
        let timer = Task { [self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { resolve(false) }
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Bool? in
                if state.result == nil { state.waiter = continuation }
                return state.result
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

/// Routes Go tsshd debug/warning messages to `ResumeDebugLogger` for
/// file-based persistence. Stateless; safe to instantiate per-connect.
nonisolated final class TrzszGoDebugLoggerBridge: NSObject, IosbridgeDebugLoggerProtocol, @unchecked Sendable {
    func onDebug(_ msg: String?) {
        guard let msg else { return }
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        ResumeDebugLogger.shared.log(msg, source: "tsshd")
    }
}

/// Bridges Go's `DiscardNotifier` interface to a `TrzszGoTransport`. tsshd
/// reports when it dropped buffered terminal data on a lossy reconnect (the
/// server's bounded output cache overflowed, or pending input was discarded).
/// Calls land on a background goroutine; the transport's nonisolated hook hops
/// to the main actor and forwards to the session so a tmux -CC gateway can do a
/// full surface reset + recapture. Counts only — no payload crosses.
nonisolated final class TrzszGoDiscardBridge: NSObject, IosbridgeDiscardNotifierProtocol, @unchecked Sendable {
    private weak var transport: TrzszGoTransport?

    init(transport: TrzszGoTransport) {
        self.transport = transport
        super.init()
    }

    // gomobile selector: first param unlabeled, subsequent params labeled by
    // their Go names — `onDiscard(_:outputLines:outputBytes:)`.
    func onDiscard(_ inputBytes: Int, outputLines: Int, outputBytes: Int) {
        guard let transport else { return }
        transport.handleDiscardFromGoCallback(
            inputBytes: inputBytes, outputLines: outputLines, outputBytes: outputBytes)
    }
}

/// Bridges Go's `HealthNotifier` interface to a `TrzszGoTransport`. tsshd's
/// heartbeat checker pushes timeout/recovery transitions so Swift never has
/// to poll `GetLastActiveTime`. Calls land on a background goroutine; the
/// transport's nonisolated hook stamps the activity cache and hops to the
/// main actor.
nonisolated final class TrzszGoHealthBridge: NSObject, IosbridgeHealthNotifierProtocol, @unchecked Sendable {
    private weak var transport: TrzszGoTransport?

    init(transport: TrzszGoTransport) {
        self.transport = transport
        super.init()
    }

    func onHealthTimeout(_ lastActiveMs: Int64) {
        transport?.handleHealthTransitionFromGoCallback(isTimeout: true, lastActiveMs: lastActiveMs)
    }

    func onHealthRecovered(_ lastActiveMs: Int64) {
        transport?.handleHealthTransitionFromGoCallback(isTimeout: false, lastActiveMs: lastActiveMs)
    }
}

#if targetEnvironment(macCatalyst)
/// Holds tsshd reconnects while macOS lacks the Graphics capability (Dark
/// Wake), so a sleeping Mac doesn't reconnect and resize a shared tmux window.
nonisolated final class TrzszGoDarkWakePauser: NSObject, IosbridgeReconnectPauserProtocol, @unchecked Sendable {
    static let shared = TrzszGoDarkWakePauser()

    /// kIOPMSystemCapabilityGraphics in IOPMrootDomain's "System Capabilities".
    private static let graphicsCapability: UInt64 = 0x02
    private let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    func pauseReason() -> String {
        // An unreadable value never blocks reconnects.
        guard rootDomain != IO_OBJECT_NULL,
              let capabilities = IORegistryEntryCreateCFProperty(
                rootDomain, "System Capabilities" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? NSNumber,
              capabilities.uint64Value & Self.graphicsCapability == 0
        else { return "" }
        return "macOS Graphics capability is unavailable (possibly Dark Wake)"
    }
}
#endif
