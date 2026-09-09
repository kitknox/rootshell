//
//  HerdrController+Legacy.swift
//  rootshell
//
//  Degraded control mode for a herdr without control streams: topology
//  comes from polling `herdr api snapshot`, and each visible pane rides its
//  own `herdr terminal session control` channel carrying server-rendered
//  frames. Input and resizes go back the same way; commands run the CLI.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

/// One `herdr terminal session control` exec channel for a visible pane.
@MainActor
final class HerdrLegacyPaneStream {
    let terminalId: String
    let paneId: String
    private let pipe: AsyncBytePipe
    private let sink: OutputSink
    private var readerTask: Task<Void, Never>?
    private(set) var closed = false
    var onClosed: (() -> Void)?

    init(terminalId: String, paneId: String, pipe: AsyncBytePipe, sink: OutputSink) {
        self.terminalId = terminalId
        self.paneId = paneId
        self.pipe = pipe
        self.sink = sink
    }

    func start() {
        let pipe = self.pipe
        readerTask = Task { [weak self] in
            var buffer = Data()
            var ended = false
            while !Task.isCancelled, !ended {
                do {
                    guard let chunk = try await pipe.read(maxBytes: 64 * 1024) else { break }
                    buffer.append(chunk)
                } catch {
                    break
                }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let self else { return }
                    if await self.handle(line: line) {
                        ended = true
                        break
                    }
                }
            }
            guard let self else { return }
            await self.readerDidEnd()
        }
    }

    private struct FrameLine: Decodable {
        let type: String
        let full: Bool?
        let bytes: String?
    }

    /// Returns true when the server closed the stream.
    private func handle(line: Data) -> Bool {
        guard !line.isEmpty, let frame = try? HerdrControl.decoder.decode(FrameLine.self, from: line) else {
            return false
        }
        switch frame.type {
        case "terminal.frame":
            guard let encoded = frame.bytes, let bytes = Data(base64Encoded: encoded) else { return false }
            var out = Data("\u{1b}[?2026h".utf8)
            if frame.full == true {
                out.append(contentsOf: "\u{1b}[0m\u{1b}[H\u{1b}[2J".utf8)
            }
            out.append(bytes)
            out.append(contentsOf: "\u{1b}[?2026l".utf8)
            sink.emit(out)
            return false
        case "terminal.closed":
            return true
        default:
            return false
        }
    }

    private func readerDidEnd() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }

    private func send(_ object: [String: Any]) {
        guard !closed, var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0A)
        let pipe = self.pipe
        Task { try? await pipe.write(line) }
    }

    func sendInput(_ data: Data) {
        send(["type": "terminal.input", "bytes": data.base64EncodedString()])
    }

    func resize(cols: Int, rows: Int) {
        send(["type": "terminal.resize", "cols": cols, "rows": rows])
    }

    func close() {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        let pipe = self.pipe
        Task {
            var release = Data("{\"type\":\"terminal.release\"}".utf8)
            release.append(0x0A)
            try? await pipe.write(release)
            await pipe.close()
        }
    }
}

extension HerdrController {

    private static let legacyPollInterval: Duration = .seconds(2)
    private static let legacyMaxResponseBytes = 8 * 1024 * 1024

    /// Switches to the degraded mode after `control.open` showed the host
    /// herdr has no control stream.
    func startLegacyMode(reason: String) {
        guard mode == .raw, !didEnd else { return }
        mode = .legacy
        isActive = true
        reconnectAttempt = 0
        Self.logger.info("herdr control: degraded mode (\(reason))")
        gateway?.writeToGhostty(string:
            "\r\n\u{1b}[33mherdr control mode: \(reason). Running in degraded mode: visible panes only, server-rendered. Upgrade herdr on the host for full control mode.\u{1b}[0m\r\n")
        NotificationCenter.default.post(name: .herdrControlStateDidChange, object: gatewayUUID)
        legacyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.legacyPollOnce()
                try? await Task.sleep(for: Self.legacyPollInterval)
            }
        }
    }

    func stopLegacyMode() {
        legacyPollTask?.cancel()
        legacyPollTask = nil
        for stream in legacyStreams.values {
            stream.close()
        }
        legacyStreams.removeAll()
        legacyOpening.removeAll()
    }

    /// Runs one herdr CLI invocation on the gateway's connection and
    /// returns its stdout.
    func legacyRun(args: String) async throws -> Data {
        guard let gateway else { throw HerdrChannelError.closed }
        let command = SSHConfig.herdrCommandLine(sessionName: sessionName, args: args)
        let pipe = try await HerdrChannelFactory.open(command: command, on: gateway)
        var output = Data()
        defer { Task { await pipe.close() } }
        while let chunk = try await pipe.read(maxBytes: 64 * 1024) {
            output.append(chunk)
            if output.count > Self.legacyMaxResponseBytes {
                throw HerdrChannelError.malformed("herdr output exceeds \(Self.legacyMaxResponseBytes) bytes")
            }
        }
        return output
    }

    func legacyPollOnce() async {
        guard mode == .legacy, !didEnd, let gateway, HerdrChannelFactory.canOpen(for: gateway) else { return }
        do {
            let output = try await legacyRun(args: "api snapshot")
            guard mode == .legacy, !didEnd else { return }
            // The reply is one JSON line; tolerate chatter around it.
            guard let line = output.split(separator: 0x0A).last(where: { $0.first == UInt8(ascii: "{") }) else {
                return
            }
            let fingerprint = line.hashValue
            guard fingerprint != legacySnapshotFingerprint else { return }
            let snapshot = try HerdrControl.decoder.decode(
                HerdrControl.Response<HerdrControl.SessionSnapshotResult>.self,
                from: Data(line)
            ).result.snapshot
            legacySnapshotFingerprint = fingerprint
            applySnapshot(snapshot)
        } catch {
            Self.logger.warning("herdr degraded poll failed: \(error.localizedDescription)")
        }
    }

    /// Only the selected tab's panes hold a channel; the rest release
    /// theirs so a large session never opens dozens of exec channels.
    func legacyReconcileAttaches() {
        guard mode == .legacy else { return }
        let selected = tabsModel.selectedTabID
        for (terminalId, session) in paneSessions {
            let visible = paneViews[terminalId]?.containingTabID == selected && !Ghostty.isAppBackgroundedAtomic
            if visible {
                legacyOpenStream(for: session)
            } else if let stream = legacyStreams.removeValue(forKey: terminalId) {
                stream.close()
            }
        }
    }

    private func legacyOpenStream(for session: HerdrPaneSession) {
        let terminalId = session.terminalId
        guard legacyStreams[terminalId] == nil, !legacyOpening.contains(terminalId),
              let gateway, let grid = legacyGrids[terminalId] ?? legacySurfaceGrid(terminalId),
              let paneId = paneInfos.values.first(where: { $0.terminal_id == terminalId })?.pane_id else { return }
        legacyOpening.insert(terminalId)
        if let view = paneViews[terminalId] {
            TerminalBellSuppressor.suppressRebuild(view.uuid)
        }
        let command = SSHConfig.herdrCommandLine(
            sessionName: sessionName,
            args: "terminal session control \(paneId) --takeover --cols \(grid.cols) --rows \(grid.rows)"
        )
        Task { [weak self] in
            defer { self?.legacyOpening.remove(terminalId) }
            do {
                let pipe = try await HerdrChannelFactory.open(command: command, on: gateway)
                guard let self, self.mode == .legacy, self.paneSessions[terminalId] === session else {
                    await pipe.close()
                    return
                }
                let stream = HerdrLegacyPaneStream(
                    terminalId: terminalId,
                    paneId: paneId,
                    pipe: pipe,
                    sink: session.outputSink
                )
                stream.onClosed = { [weak self, weak stream] in
                    guard let self, let stream, self.legacyStreams[terminalId] === stream else { return }
                    self.legacyStreams.removeValue(forKey: terminalId)
                }
                self.legacyStreams[terminalId] = stream
                stream.start()
            } catch {
                HerdrController.logger.warning("herdr degraded attach \(terminalId) failed: \(error.localizedDescription)")
            }
        }
    }

    private func legacySurfaceGrid(_ terminalId: String) -> (rows: Int, cols: Int)? {
        guard let size = paneViews[terminalId]?.surfaceSize, size.rows >= 2, size.columns >= 4 else { return nil }
        return (Int(size.rows), Int(size.columns))
    }

    func legacyInput(_ session: HerdrPaneSession, _ data: Data) {
        legacyStreams[session.terminalId]?.sendInput(data)
    }

    func legacyGridDidChange(_ session: HerdrPaneSession, rows: Int, cols: Int) {
        guard rows >= 2, cols >= 4 else { return }
        legacyGrids[session.terminalId] = (rows, cols)
        if let stream = legacyStreams[session.terminalId] {
            stream.resize(cols: cols, rows: rows)
        } else {
            legacyReconcileAttaches()
        }
    }

    func legacyPaneDidStop(_ session: HerdrPaneSession) {
        legacyGrids.removeValue(forKey: session.terminalId)
        legacyStreams.removeValue(forKey: session.terminalId)?.close()
    }

    /// Runs a CLI command for a user action and polls right after so the
    /// resulting topology lands without waiting for the next tick.
    func legacyCommand(_ args: String) {
        Task { [weak self] in
            do {
                _ = try await self?.legacyRun(args: args)
            } catch {
                HerdrController.logger.warning("herdr degraded command failed: \(error.localizedDescription)")
            }
            await self?.legacyPollOnce()
        }
    }
}
