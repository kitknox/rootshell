import Foundation
import os

/// The saved form of a tssh terminal: VT bytes that rebuild both screens, their
/// keyboard stacks and saved cursors, the modes, the margins and the pen in a
/// fresh surface. GhosttyKit writes them from its own terminal state
/// (`ghostty_surface_restoration_snapshot`), so the app neither mirrors the
/// output stream nor sends queries through it.
nonisolated enum TerminalRestorationSnapshot {
    /// A replay starts with RIS, which also tells it apart from the JSON
    /// envelope that builds with an app-side protocol mirror wrote.
    private static let reset = Data("\u{1b}c".utf8)

    private struct Envelope: Decodable {
        let version: Int
        let replay: Data
    }

    /// One capture, split for the two files it is saved to.
    struct Parts: Equatable {
        /// The primary screen dump, trimmed to the scrollback size limit.
        let scrollback: Data
        /// The whole replay around that same trimmed dump. Nil if the dump had
        /// to be cut where no line ends: a replay must not start mid-sequence.
        let replay: Data?
    }

    /// True for a complete replay: it resets the terminal and carries the
    /// scrollback itself, so nothing needs to be queued ahead of it, and it
    /// has to reach the terminal whole.
    static func isReplay(_ bytes: Data) -> Bool { bytes.starts(with: reset) }

    /// The replay in a saved snapshot file, or nil if the bytes are not one.
    static func replay(fromSaved bytes: Data) -> Data? {
        if isReplay(bytes) { return bytes }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes),
              envelope.version == 1, envelope.replay.starts(with: reset) else { return nil }
        return envelope.replay
    }

    /// Keeps the newest `maxBytes` of a screen dump, starting at a line.
    /// `startsAtLine` is false if no line ended inside the kept part.
    static func trimmed(_ dump: Data, maxBytes: Int) -> (data: Data, startsAtLine: Bool) {
        guard dump.count > maxBytes else { return (dump, true) }
        let cut = dump.index(dump.startIndex, offsetBy: dump.count - maxBytes)
        if let newline = dump[cut...].firstIndex(of: 0x0a) {
            return (Data(dump[dump.index(after: newline)...]), true)
        }
        return (Data(dump[cut...]), false)
    }

    /// Splits a Ghostty snapshot whose primary screen dump occupies `primary`.
    /// Nil if that range does not lie inside the snapshot.
    static func parts(of snapshot: Data, primary: Range<Int>, maxScrollbackBytes: Int) -> Parts? {
        guard primary.lowerBound >= 0, primary.upperBound <= snapshot.count else { return nil }
        let base = snapshot.startIndex
        let dump = snapshot.subdata(in: (base + primary.lowerBound)..<(base + primary.upperBound))
        let scrollback = trimmed(dump, maxBytes: maxScrollbackBytes)
        guard scrollback.data.count != dump.count else { return Parts(scrollback: dump, replay: snapshot) }
        guard scrollback.startsAtLine else { return Parts(scrollback: scrollback.data, replay: nil) }
        var replay = snapshot.subdata(in: base..<(base + primary.lowerBound))
        replay.append(scrollback.data)
        replay.append(snapshot.subdata(in: (base + primary.upperBound)..<snapshot.endIndex))
        return Parts(scrollback: scrollback.data, replay: replay)
    }
}

/// A byte offset in a terminal's pipe, comparable with
/// `ghostty_surface_parsed_bytes` of the surface reading that pipe.
nonisolated struct TerminalPipeOffset: Sendable, Equatable {
    /// Identifies the pipe: each surface counts its parsed bytes from zero.
    let pipe: UInt64
    let end: UInt64
}

/// Travels with one chunk of output to the pipe writer. Called once: with
/// where the chunk's last byte went into the pipe, or with nil if the chunk
/// was dropped on the way.
typealias TerminalWriteMark = @Sendable (TerminalPipeOffset?) -> Void

/// One mark for chunks that were merged into one: each is told what became
/// of the merged chunk.
nonisolated func mergedTerminalWriteMark(_ marks: [TerminalWriteMark]) -> TerminalWriteMark? {
    guard !marks.isEmpty else { return nil }
    return { offset in marks.forEach { $0(offset) } }
}

/// What a save gathered for a terminal may write once it has read the
/// surface, which can be later and off the main actor.
nonisolated struct TerminalPersistedContents: Sendable {
    /// The session and the surface the terminal had when the save was
    /// gathered. A save that outlives either would write that session's
    /// kind of files, or that surface's screen, over the next one's, so it
    /// is discarded.
    let session: TerminalRemoteOutputMarker.Session
    /// Non-nil for a tssh terminal: the restoration snapshot is saved beside
    /// the scrollback, if Ghostty had parsed this many bytes of the pipe
    /// when the snapshot was taken. Nil saves the scrollback alone.
    let snapshotParseTarget: UInt64?
}

/// Where the remote program of the adopted tssh session first wrote into the
/// terminal's pipe. Until Ghostty has parsed that far the surface still shows
/// connection progress, which must not replace the saved remote screen.
nonisolated final class TerminalRemoteOutputMarker: Sendable {
    /// Whose remote program wrote the bytes being delivered.
    enum RemoteDelivery: Sendable {
        /// The session the receiving sink was made for. Set by the tssh
        /// transport around the bytes it received from the server; what the
        /// session writes itself (escape help, a channel reset) goes through
        /// the same sink without it.
        case ownSession
        /// An embedded tssh session, which hands its output to the parent
        /// session's sink on a later main-actor turn. That sink also carries
        /// the local prompt and the connection spinner.
        case session(UInt64)
    }

    /// Set, for the duration of the synchronous delivery, while bytes a
    /// remote program wrote travel to an output sink.
    @TaskLocal static var remoteDelivery: RemoteDelivery?

    /// One session of the terminal on one surface, as seen by a save.
    struct Session: Sendable {
        fileprivate let marker: TerminalRemoteOutputMarker
        fileprivate let id: UInt64
        fileprivate let pipe: UInt64

        /// False once another session took over the terminal, or its
        /// surface and pipe were replaced: a save still holding the old
        /// surface would read a screen that is no longer the terminal's.
        var isCurrent: Bool { marker.state.withLock { $0.session == id && $0.pipes == pipe } }
    }

    private enum Phase {
        case none
        /// The first remote chunk is on its way to the pipe, under this claim.
        case arriving(UInt64)
        case written(TerminalPipeOffset)
    }
    private struct State {
        var session: UInt64 = 0
        /// Counts the pipes the terminal has had.
        var pipes: UInt64 = 0
        var claims: UInt64 = 0
        var phase = Phase.none
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A new session starts: nothing from its remote program yet. Returns
    /// the session's id, which its output has to present to `claimFirstWrite`.
    @discardableResult
    func beginSession() -> UInt64 {
        state.withLock { state in
            state.session &+= 1
            state.phase = .none
            return state.session
        }
    }

    /// The surface and its pipe were replaced under the same session: the
    /// next remote chunk is the first one in the new pipe. A chunk claimed
    /// for the old pipe no longer counts, even if its mark still reports.
    func pipeChanged() {
        state.withLock { state in
            state.pipes &+= 1
            state.phase = .none
        }
    }

    /// For a chunk the remote program of `session` wrote. Returns the mark
    /// that chunk must carry to the pipe writer if it is the first of the
    /// current session, nil otherwise: also for output of a session that has
    /// been replaced since, which may still arrive.
    func claimFirstWrite(session: UInt64) -> TerminalWriteMark? {
        let claim: UInt64? = state.withLock { state in
            guard state.session == session, case .none = state.phase else { return nil }
            state.claims &+= 1
            state.phase = .arriving(state.claims)
            return state.claims
        }
        guard let claim else { return nil }
        return { [self] offset in
            state.withLock { state in
                // Only the claim still waiting: a new session or a new pipe
                // has dropped it, and may have made a claim of its own.
                guard case .arriving(claim) = state.phase else { return }
                // A dropped chunk leaves the next remote chunk to be first.
                state.phase = offset.map { .written($0) } ?? .none
            }
        }
    }

    /// The current session, and how many bytes of `pipe` Ghostty must have
    /// parsed for a snapshot to show its remote program's output: nil until
    /// that program's first write is in `pipe`.
    func saveState(pipe: UInt64) -> (session: Session, parseTarget: UInt64?) {
        state.withLock { state in
            var target: UInt64?
            if case .written(let offset) = state.phase, offset.pipe == pipe { target = offset.end }
            return (Session(marker: self, id: state.session, pipe: state.pipes), target)
        }
    }
}

/// Keeps the saves of one terminal in the order their surfaces were read. A
/// save reads the surface on one thread and writes its files later on
/// another, so an older one can finish after a newer one and must not
/// replace it. `capture` is the number Ghostty gave the snapshot.
nonisolated final class TerminalSaveOrder: @unchecked Sendable {
    enum Standing {
        /// A later capture of the terminal has been accepted already.
        case superseded
        /// The newest capture, and the files on disk are those of the one
        /// accepted before it.
        case current
        /// The newest capture, but an older one has not written its files
        /// yet or failed to: what is on disk is not known to be the last
        /// accepted screen, so this one must be written even if unchanged.
        case aheadOfPendingWrite
    }

    private struct Entry {
        var accepted: UInt64 = 0
        var onDisk: UInt64 = 0
    }
    private struct State {
        var entries: [UUID: Entry] = [:]
        var registrations: [UUID: UInt64] = [:]
        var registered: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Held while one save writes its files.
    private let writing = NSLock()

    /// The terminal starts saving, possibly again under the same UUID with
    /// a new view and surface. Saves gathered for an earlier registration
    /// are refused from here on. Returns what they have to present.
    ///
    /// There is no way to take a registration back: when a scene is torn
    /// down its terminals stop saving, but the save gathered just before,
    /// which still holds the surface, is the last one and has to land.
    func register(_ uuid: UUID) -> UInt64 {
        state.withLock { state in
            state.registered &+= 1
            state.registrations[uuid] = state.registered
            return state.registered
        }
    }

    func registration(of uuid: UUID) -> UInt64? {
        state.withLock { $0.registrations[uuid] }
    }

    /// Registers a capture right after it was taken. From then on no older
    /// capture of the terminal can be written. A capture gathered for an
    /// earlier registration is superseded whatever its number: Ghostty
    /// numbers captures in the order they are read, and the old surface may
    /// have been read last.
    func accept(_ uuid: UUID, capture: UInt64, registration: UInt64) -> Standing {
        state.withLock { state in
            guard state.registrations[uuid] == registration else { return .superseded }
            var entry = state.entries[uuid] ?? Entry()
            guard capture > entry.accepted else { return .superseded }
            let pending = entry.accepted != entry.onDisk
            entry.accepted = capture
            state.entries[uuid] = entry
            return pending ? .aheadOfPendingWrite : .current
        }
    }

    /// No accepted capture of the terminal is still waiting to write or
    /// failed to: the disk holds the newest accepted one.
    func isSettled(_ uuid: UUID) -> Bool {
        state.withLock { state in
            state.entries[uuid].map { $0.accepted == $0.onDisk } ?? true
        }
    }

    /// Starts writing the files of `capture`. False if a later capture was
    /// accepted meanwhile, or the terminal was registered again: the write
    /// runs detached, after the replacement may have started. After true,
    /// call `endWrite` on the same thread.
    func beginWrite(_ uuid: UUID, capture: UInt64, registration: UInt64) -> Bool {
        writing.lock()
        let mayWrite = state.withLock { state in
            state.registrations[uuid] == registration && state.entries[uuid]?.accepted == capture
        }
        if !mayWrite { writing.unlock() }
        return mayWrite
    }

    func endWrite(_ uuid: UUID, capture: UInt64, succeeded: Bool) {
        if succeeded { state.withLock { $0.entries[uuid]?.onDisk = capture } }
        writing.unlock()
    }
}
