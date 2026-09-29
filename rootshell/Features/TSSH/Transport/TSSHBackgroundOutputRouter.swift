//
//  TSSHBackgroundOutputRouter.swift
//  rootshell
//
//  Decides where tssh output goes while the app is backgrounded. Pure state,
//  no Go or UIKit dependency, so the logic tests compile it directly.
//

import os

/// Routes tssh output that arrives while the app is backgrounded, and counts
/// what went straight to the terminal so the foreground can settle it once.
///
/// Write-through (the default) hands backgrounded output to the terminal as
/// it arrives: Ghostty parses it while the app is still alive in the
/// background, so resume has no backlog to replay. Replaying seconds of TUI
/// frames on resume froze the UI. A `tmux -CC` or herdr control gateway turns
/// it off and keeps the bounded background buffer, because that control
/// stream relies on the buffer's discard→reset ordering.
nonisolated final class TrzszBackgroundOutputRouter: @unchecked Sendable {
    nonisolated enum Route: Equatable, Sendable {
        /// Foreground: the caller's normal delivery path.
        case foreground
        /// Backgrounded with write-through on: emit to the terminal now.
        case writeThrough
        /// Backgrounded with write-through off: hold in the background buffer.
        case buffer
    }

    nonisolated private struct State: Sendable {
        var writeThroughEnabled = true
        var writtenThroughBytes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isWriteThroughEnabled: Bool {
        state.withLock { $0.writeThroughEnabled }
    }

    func setWriteThroughEnabled(_ enabled: Bool) {
        state.withLock { $0.writeThroughEnabled = enabled }
    }

    /// Route one output chunk. A `.writeThrough` chunk counts toward the next
    /// `takeWrittenThroughBytes()`.
    func route(byteCount: Int, isBackgrounded: Bool) -> Route {
        guard isBackgrounded else { return .foreground }
        return state.withLock { state in
            guard state.writeThroughEnabled else { return .buffer }
            state.writtenThroughBytes += byteCount
            return .writeThrough
        }
    }

    /// Bytes written through since the last call, then zero. Take-and-clear,
    /// so the several resume paths that settle write-through pay only once.
    func takeWrittenThroughBytes() -> Int {
        state.withLock { state in
            let taken = state.writtenThroughBytes
            state.writtenThroughBytes = 0
            return taken
        }
    }
}

/// Whether a tssh session has a `tmux -CC` or herdr control gateway, live or
/// about to be launched, and so must keep backgrounded output buffered.
nonisolated enum TrzszControlGatewayPolicy {
    /// - Parameters:
    ///   - isLive: the reconcile registered a live gateway on this session.
    ///   - hasEnded: a gateway on this session exited to a plain shell.
    ///   - wasResumed: the session was resumed, which skips the auto-start
    ///     launch command.
    ///   - autoStartsControlMode: the connection is configured to launch
    ///     `tmux -CC` on connect.
    static func expectsGateway(
        isLive: Bool,
        hasEnded: Bool,
        wasResumed: Bool,
        autoStartsControlMode: Bool
    ) -> Bool {
        if isLive { return true }
        guard !hasEnded, !wasResumed else { return false }
        return autoStartsControlMode
    }
}
