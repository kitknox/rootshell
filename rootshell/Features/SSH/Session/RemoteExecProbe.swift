//
//  RemoteExecProbe.swift
//  rootshell
//
//  Runs a short out-of-band command on the connection a pane already holds:
//  a separate exec channel on a live Citadel client, the tssh transport's
//  own remote-command call, or the local helper on macOS. Never touches the
//  user's interactive shell.
//
//  Extracted from ProjectProbeRunner so every feature that needs a quiet
//  one-shot command (project facts, usage probes) shares one transport core —
//  and, deliberately, one tssh probe slot per session across all of them.
//

import Foundation
#if canImport(Citadel)
import Citadel
import NIO
import NIOFoundationCompat
#endif

/// One-shot race between a blocking call and a deadline.
///
/// Needed because a structured task group waits for its children even after
/// cancelling them, and the tssh transport blocks in a continuation with no
/// cancellation path — so a group would not release at the deadline at all.
/// First result wins; later ones are dropped. (id=agent-project)
private actor ProbeRace {
    private var continuation: CheckedContinuation<String, Error>?
    private var settled: Result<String, Error>?

    var value: String {
        get async throws {
            if let settled { return try settled.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func finish(_ result: Result<String, Error>) {
        guard settled == nil else { return }
        settled = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

@MainActor
enum RemoteExecProbe {

    /// Probe answers are a handful of short lines, so this default cap is
    /// generous. It exists only so a pathological host cannot stream.
    /// Nonisolated: default argument values evaluate outside the actor.
    nonisolated static let defaultMaxResponseBytes = 64 * 1024

    /// Long enough for a cold command on a slow link, short enough that a
    /// wedged host does not hold a probe slot.
    nonisolated static let defaultTimeout: TimeInterval = 6

    enum ProbeError: Error {
        case notConnected
        case timedOut
        case unsupportedSession
        /// A probe is already outstanding on this session's transport.
        case busy
    }

    /// tssh sessions with a probe still running on the transport, including one
    /// whose caller already gave up at the deadline, with the time it started.
    ///
    /// Bounds the queue to one per session. The timestamp is the safety valve:
    /// a call that never returns would otherwise hold the slot forever and
    /// disable probing for that session permanently, which is a worse failure
    /// than the accumulation this prevents. (id=agent-project)
    private struct TrzszSlot {
        let generation: UInt64
        let startedAt: Date
    }
    private static var trzszProbesOutstanding: [ObjectIdentifier: TrzszSlot] = [:]

    /// Identifies which call owns a session's slot. Without it, cleanup was
    /// "remove whatever is there": a probe that outlived the expiry and then
    /// returned would release the slot of the SUCCESSOR that had legitimately
    /// replaced it, letting a third probe start while the second still ran —
    /// the exact unbounded queueing the slot exists to prevent.
    private static var trzszProbeGeneration: UInt64 = 0

    /// How long an outstanding call may hold its slot before another is
    /// allowed. Generous next to the 6s deadline, so it only releases calls
    /// that are genuinely wedged.
    private static let trzszSlotExpiry: TimeInterval = 60

    /// Whether a probe could run for this pane RIGHT NOW.
    ///
    /// Checked synchronously before dispatching, so an unusable transport costs
    /// nothing and no failure has to be remembered. Capability is a property of
    /// the live SESSION, not of the host: a Citadel client that is briefly nil
    /// while connecting means "not yet", and caching that as "unsupported"
    /// silently disabled every probe to that host for the rest of the run.
    /// (id=agent-project)
    static func canProbe(_ sessionOwner: Ghostty.TerminalView) -> Bool {
        #if targetEnvironment(macCatalyst)
        if sessionOwner.connectionConfig.underlyingSSHConfig == nil { return true }
        #endif
        if TmuxController.gatewayTrzszSession(for: sessionOwner.session) != nil { return true }
        #if canImport(Citadel)
        if let citadel = sessionOwner.session as? CitadelSSHSession, citadel.client != nil {
            return true
        }
        #endif
        return false
    }

    /// Runs `command` on the host behind `sessionOwner`'s session and returns
    /// the raw output, capped at `maxResponseBytes`.
    ///
    /// `sessionOwner` is the pane that actually HOLDS the connection: for an
    /// ordinary SSH pane that is the pane itself, for a tmux -CC pane it is
    /// the gateway, since a pane rides the gateway's connection. The caller
    /// resolves that.
    ///
    /// Callers frame their output with nonce markers and end their script
    /// `exit 0`: a non-zero exit makes Citadel raise CommandFailed and
    /// DISCARD the output, and truncation must be distinguishable from a
    /// genuine negative answer.
    static func run(
        _ command: String,
        on sessionOwner: Ghostty.TerminalView,
        timeout: TimeInterval = defaultTimeout,
        maxResponseBytes: Int = defaultMaxResponseBytes
    ) async throws -> String {
        #if targetEnvironment(macCatalyst)
        // A LOCAL macOS shell (including a local tmux -CC gateway) has no SSH
        // client to borrow, but the helper already runs commands out-of-band
        // for exactly this kind of work. Without this branch, a local pane
        // could never answer a probe at all.
        if sessionOwner.connectionConfig.underlyingSSHConfig == nil {
            // The helper is started on demand, not kept alive for us. Without
            // this the socket read fails with "connection closed" whenever no
            // local shell happens to have started it already, which is exactly
            // the intermittency this looked like. (id=agent-project)
            guard await HelperConnection.shared.ensureHelperRunning() else {
                throw ProbeError.notConnected
            }
            let result = try await HelperConnection.shared.executeCommand(
                command: command,
                timeout: timeout,
                // Same bound as the remote transports: a local command can
                // stream just as much, and the caller's framing detects the
                // truncation exactly as it does for a capped SSH channel.
                maxOutputBytes: maxResponseBytes
            )
            guard !result.timedOut else { throw ProbeError.timedOut }
            return result.output
        }
        #endif

        // tssh runs the probe over its OWN live transport, so the command is a
        // child of the same tsshd as the pane's shell. A separate connection
        // would cost an extra authentication and, worse, land outside that
        // process tree — where nothing can identify which pane it belongs to.
        if let trzsz = TmuxController.gatewayTrzszSession(for: sessionOwner.session) {
            // A timed-out call is released to the CALLER but keeps running on
            // the transport, so without this a stalled command would have
            // another queued behind it every retry, without bound. One
            // outstanding probe per session; the rest are refused until it
            // returns. (id=agent-project)
            let sessionID = ObjectIdentifier(trzsz)
            let now = Date()
            if let slot = trzszProbesOutstanding[sessionID],
               now.timeIntervalSince(slot.startedAt) < trzszSlotExpiry {
                throw ProbeError.busy
            }
            trzszProbeGeneration &+= 1
            let generation = trzszProbeGeneration
            trzszProbesOutstanding[sessionID] = TrzszSlot(generation: generation, startedAt: now)
            // The Go transport call blocks in a checked continuation with no
            // cancellation path, so a task group would NOT return at the
            // deadline: it waits for its children even after cancelling them.
            // Race through a one-shot box instead, so the deadline actually
            // releases this call and the host stops being marked
            // probe-in-flight. The Go call is left to finish on its own.
            let cap = maxResponseBytes
            let box = ProbeRace()
            Task.detached {
                do {
                    let bytes = try await trzsz.runProbeCommand(command)
                    await box.finish(.success(String(decoding: bytes.prefix(cap), as: UTF8.self)))
                } catch {
                    await box.finish(.failure(error))
                }
                // Released only when the blocking call really returns, however
                // long after the deadline that is -- that is what bounds the
                // queue to one. Only if this call STILL owns the slot: past
                // the expiry a successor may already hold it, and clearing
                // that would let a third probe in alongside it.
                await MainActor.run {
                    guard RemoteExecProbe.trzszProbesOutstanding[sessionID]?.generation
                        == generation else { return }
                    RemoteExecProbe.trzszProbesOutstanding.removeValue(forKey: sessionID)
                }
            }
            let timer = Task.detached { [timeout] in
                try? await Task.sleep(for: .seconds(timeout))
                await box.finish(.failure(ProbeError.timedOut))
            }
            defer { timer.cancel() }

            return try await box.value
        }

        #if canImport(Citadel)
        // LIVE connections only. Opening a connection of our own for a
        // background probe would cost an extra authentication, and on a host
        // with 2FA it would prompt the user out of nowhere.
        guard let session = sessionOwner.session as? CitadelSSHSession,
              let client = session.client
        else {
            throw ProbeError.unsupportedSession
        }

        let cap = maxResponseBytes
        let deadline = timeout

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @Sendable in
                let buffer = try await client.executeCommand(command, maxResponseSize: cap)
                // Tolerant decode, matching session discovery: a truncated
                // response should still parse to whatever arrived intact.
                return String(decoding: Data(buffer: buffer), as: UTF8.self)
            }
            group.addTask { @Sendable in
                try await Task.sleep(for: .seconds(deadline))
                throw ProbeError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        #else
        throw ProbeError.unsupportedSession
        #endif
    }
}
