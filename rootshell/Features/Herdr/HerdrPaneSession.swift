//
//  HerdrPaneSession.swift
//  rootshell
//
//  The TerminalSession a projected herdr pane surface is bound to. It owns no
//  transport: bytes arrive from the controller's channel through an
//  OutputSink and input goes back through the controller. Being a real
//  TerminalSession keeps the response pipeline, size updates, bell and title
//  plumbing exactly as they are for SSH panes.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// Off-main fan-out of raw terminal records to pane sinks, keyed by attach id.
/// The channel actor calls into this directly so output never waits for the
/// main actor.
nonisolated final class HerdrOutputRouter: @unchecked Sendable {
    /// Bytes held for an attach whose sink is not registered yet.
    private static let maxPendingBytes = 8 * 1024 * 1024

    private let lock = UnfairLock()
    private var sinks: [String: OutputSink] = [:]
    /// Records that arrived before `register`: the snapshot follows the
    /// attach response on the same stream, so it can beat the main-actor
    /// hop that registers the sink.
    private var pending: [String: [Data]] = [:]
    private var pendingBytes = 0

    func register(attachId: String, sink: OutputSink) {
        let backlog: [Data] = lock.withLock {
            sinks[attachId] = sink
            let held = pending.removeValue(forKey: attachId) ?? []
            pendingBytes -= held.reduce(0) { $0 + $1.count }
            return held
        }
        for data in backlog {
            sink.emit(data)
        }
    }

    func unregister(attachId: String) {
        lock.withLock {
            _ = sinks.removeValue(forKey: attachId)
            if let held = pending.removeValue(forKey: attachId) {
                pendingBytes -= held.reduce(0) { $0 + $1.count }
            }
        }
    }

    func removeAll() {
        lock.withLock {
            sinks.removeAll()
            pending.removeAll()
            pendingBytes = 0
        }
    }

    private func deliver(attachId: String, _ data: Data) {
        let sink: OutputSink? = lock.withLock {
            if let sink = sinks[attachId] { return sink }
            guard pendingBytes + data.count <= Self.maxPendingBytes else { return nil }
            pending[attachId, default: []].append(data)
            pendingBytes += data.count
            return nil
        }
        sink?.emit(data)
    }

    func write(attachId: String, _ data: Data) {
        deliver(attachId: attachId, data)
    }

    func applySnapshot(_ record: HerdrControl.SnapshotRecord) {
        deliver(attachId: record.attach_id, Self.replayBytes(for: record.snapshot))
    }

    /// Composes the byte sequence that rebuilds a surface from a snapshot:
    /// clear everything, replay the primary history, switch to and paint the
    /// alternate screen when it is active, restore modes, then the cursor.
    /// Wrapped in synchronized output so the rebuild never flickers.
    static func replayBytes(for snapshot: HerdrControl.TerminalSnapshot) -> Data {
        var out = Data()
        out.append(contentsOf: "\u{1b}[?2026h\u{1b}[?1049l\u{1b}[0m\u{1b}[?25l\u{1b}[3J\u{1b}[2J\u{1b}[H".utf8)
        if let primary = snapshot.primary {
            out.append(contentsOf: primary.utf8)
        }
        if snapshot.active_screen == "alternate" {
            out.append(contentsOf: "\u{1b}[?1049h\u{1b}[2J\u{1b}[H".utf8)
            if let alternate = snapshot.alternate {
                out.append(contentsOf: alternate.utf8)
            }
        }
        out.append(contentsOf: snapshot.state_ansi.utf8)
        out.append(contentsOf: "\u{1b}[\(snapshot.cursor.y + 1);\(snapshot.cursor.x + 1)H".utf8)
        out.append(contentsOf: "\u{1b}[?2026l".utf8)
        return out
    }
}

@MainActor
final class HerdrPaneSession: TerminalSession {
    let pty = TerminalPTY()
    private(set) var isRunning = false

    let terminalId: String
    private(set) var paneId: String
    /// Live attach id once the controller's `terminal.attach` succeeded.
    var attachId: String?
    private(set) weak var controller: HerdrController?

    /// Delivered off-main by the router; mirrors the callback properties.
    let outputSink = OutputSink()

    var onOutput: (@Sendable (String) -> Void)? {
        didSet { outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }
    var onOutputData: (@Sendable (Data) -> Void)? {
        didSet { outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?

    var connectionInfo: ConnectionInfo? { controller?.gatewayConnectionInfo }

    init(controller: HerdrController, terminalId: String, paneId: String) {
        self.controller = controller
        self.terminalId = terminalId
        self.paneId = paneId
    }

    func updatePaneId(_ paneId: String) {
        self.paneId = paneId
    }

    func start() async throws {
        isRunning = true
        controller?.paneSessionDidStart(self)
        onReady?()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        controller?.paneSessionDidStop(self)
    }

    func sendInput(_ data: Data) {
        controller?.sendInput(from: self, data)
    }

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        controller?.paneGridDidChange(self, rows: Int(size.rows), cols: Int(size.cols))
    }

    /// The pane went away on the server: end the session so the tab's
    /// ordinary close path runs.
    func endedRemotely() {
        guard isRunning else { return }
        isRunning = false
        onSessionEnd?()
    }
}
