//
//  HerdrController+Legacy.swift
//  rootshell
//
//  Degraded control mode for a herdr without control streams: topology
//  comes from polling `herdr api snapshot`, and each visited pane rides its
//  own PTY running `herdr terminal attach`. The stock client translates
//  mouse input and scrollback; JSON frame streams remain a compatibility fallback.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

extension HerdrController {

    private static let legacyPollInterval: Duration = .seconds(2)
    private static let legacyMaxResponseBytes = 8 * 1024 * 1024

    /// Uses the stock client when control streams are unavailable or fallback
    /// mode was explicitly requested in Debug settings.
    func startLegacyMode(reason: String, recommendUpgrade: Bool = true) {
        guard mode == .raw, !didEnd else { return }
        mode = .legacy
        isActive = true
        reconnectAttempt = 0
        Self.logger.info("herdr control: degraded mode (\(reason))")
        let upgradeHint = recommendUpgrade ? " Upgrade herdr on the host for raw control streams." : ""
        gateway?.writeToGhostty(string:
            "\r\n\u{1b}[33mherdr control mode: \(reason). Running with server-rendered panes.\(upgradeHint)\u{1b}[0m\r\n")
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
        for opening in legacyOpening.values { opening.task.cancel() }
        for terminalId in Array(legacyStreams.keys) { legacyCloseStream(terminalId) }
        legacyStreams.removeAll()
        // Keep pending opens until their cleanup finishes; a late successful
        // open must close its PTY before another attempt can take ownership.
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
        guard mode == .legacy, !didEnd, !legacySuspended,
              let gateway, HerdrChannelFactory.canOpen(for: gateway) else { return }
        // Reattach dropped streams even if the topology fingerprint is unchanged.
        defer { legacyReconcileAttaches() }
        do {
            let output = try await legacyRun(args: "api snapshot")
            guard mode == .legacy, !didEnd else { return }
            // The reply is one JSON line; tolerate chatter around it.
            guard let line = output.split(separator: 0x0A).last(where: { $0.first == UInt8(ascii: "{") }) else {
                let text = String(decoding: output.prefix(200), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                legacyNotice("herdr api snapshot returned no JSON" + (text.isEmpty ? " (empty output)" : ": \(text)"))
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
            legacyNotice("snapshot poll failed: \(error.localizedDescription)")
        }
    }

    /// Degraded mode has no stream to report through, so a failure the user
    /// would otherwise see only as missing tabs goes to the gateway shell,
    /// once per distinct message.
    func legacyNotice(_ message: String) {
        guard !didEnd, legacyNoticesShown.insert(message).inserted else { return }
        gateway?.writeToGhostty(string: "\r\n\u{1b}[33mherdr control mode: \(message)\u{1b}[0m\r\n")
    }

    /// Open panes lazily, then retain visited panes across tab switches so
    /// their screen, selection and server viewport stay ready to return to.
    func legacyReconcileAttaches() {
        guard mode == .legacy, !didEnd else { return }
        for (terminalId, session) in paneSessions {
            if legacySuspended || Ghostty.isAppBackgroundedAtomic {
                legacyOpening[terminalId]?.task.cancel()
                legacyCloseStream(terminalId)
            } else if legacyPaneIsVisible(terminalId) {
                legacyOpenStream(for: session)
            }
        }
    }

    private func legacyPaneIsVisible(_ terminalId: String) -> Bool {
        guard !didEnd, !legacySuspended, !Ghostty.isAppBackgroundedAtomic,
              let tabId = paneViews[terminalId]?.containingTabID else { return false }
        return tabId == tabsModel.selectedTabID
    }

    private func legacyCanFinishOpen(_ terminalId: String) -> Bool {
        !didEnd && mode == .legacy && !legacySuspended && !Ghostty.isAppBackgroundedAtomic
            && paneViews[terminalId] != nil
    }

    func legacyCloseStream(_ terminalId: String) {
        if let stream = legacyStreams.removeValue(forKey: terminalId) {
            legacyClosing[terminalId] = stream.close()
        }
    }

    private func legacyOpenStream(for session: HerdrPaneSession) {
        let terminalId = session.terminalId
        guard legacyStreams[terminalId] == nil, legacyOpening[terminalId] == nil,
              let gateway, let grid = legacyGrids[terminalId] ?? legacySurfaceGrid(terminalId),
              let paneId = paneInfos.values.first(where: { $0.terminal_id == terminalId })?.pane_id else { return }
        let generation = UUID()
        let task = Task { [weak self] in
            defer {
                if self?.legacyOpening[terminalId]?.id == generation {
                    self?.legacyOpening.removeValue(forKey: terminalId)
                }
            }
            do {
                await self?.legacyClosing[terminalId]?.value
                try Task.checkCancellation()
                guard let self, self.legacyCanFinishOpen(terminalId),
                      self.paneSessions[terminalId] === session else { return }
                self.legacyClosing.removeValue(forKey: terminalId)
                let pipe: AsyncBytePipe
                if self.legacyPTYUnavailable {
                    pipe = try await self.legacyOpenJSON(paneId: paneId, grid: grid, gateway: gateway)
                } else {
                    let command = HerdrAttachCommand.make(
                        sessionName: self.sessionName,
                        terminalId: terminalId
                    )
                    do {
                        pipe = try await HerdrChannelFactory.openPTY(
                            command: command, cols: grid.cols, rows: grid.rows, on: gateway
                        )
                    } catch {
                        try Task.checkCancellation()
                        if case HerdrPTYError.unavailable = error {
                            self.legacyUseJSON(reason: error.localizedDescription)
                        } else if HerdrPTYError.isRequestRejection(error) {
                            self.legacyUseJSON(reason: error.localizedDescription)
                        } else { throw error }
                        // Retry through the normal poll after the failed PTY is closed.
                        return
                    }
                }
                guard !Task.isCancelled, self.legacyCanFinishOpen(terminalId),
                      self.legacyOpening[terminalId]?.id == generation,
                      self.paneSessions[terminalId] === session else {
                    await pipe.close()
                    return
                }
                if let view = self.paneViews[terminalId] { TerminalBellSuppressor.suppressRebuild(view.uuid) }
                let stream = HerdrLegacyPaneStream(
                    terminalId: terminalId,
                    paneId: paneId,
                    pipe: pipe,
                    sink: session.outputSink
                )
                stream.onClosed = { [weak self, weak stream] error in
                    guard let self, let stream, self.legacyStreams[terminalId] === stream else { return }
                    self.legacyCloseStream(terminalId)
                    if let error {
                        if case HerdrPTYError.unavailable = error {
                            self.legacyUseJSON(reason: error.localizedDescription)
                        } else { self.legacyNotice(error.localizedDescription) }
                    }
                }
                self.legacyStreams[terminalId] = stream
                stream.start()
                // A live resize may have happened while PTY allocation awaited.
                if let latest = self.legacyGrids[terminalId], latest != grid {
                    stream.resize(cols: latest.cols, rows: latest.rows)
                }
            } catch {
                guard !Task.isCancelled else { return }
                HerdrController.logger.warning("herdr degraded attach \(terminalId) failed: \(error.localizedDescription)")
                self?.legacyNotice("pane attach failed: \(error.localizedDescription)")
            }
        }
        legacyOpening[terminalId] = (generation, task)
    }

    private func legacyOpenJSON(paneId: String, grid: (rows: Int, cols: Int), gateway: Ghostty.TerminalView) async throws -> AsyncBytePipe {
        let command = SSHConfig.herdrCommandLine(
            sessionName: sessionName,
            args: "terminal session control \(LoginShellCommand.singleQuoted(paneId)) --takeover --cols \(grid.cols) --rows \(grid.rows)"
        )
        return try await HerdrChannelFactory.open(command: command, on: gateway)
    }

    private func legacyUseJSON(reason: String) {
        guard !legacyPTYUnavailable else { return }
        legacyPTYUnavailable = true
        legacyNotice("\(reason). Using JSON pane frames; mouse input is unavailable in this fallback.")
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
        legacyOpening[session.terminalId]?.task.cancel()
        legacyGrids.removeValue(forKey: session.terminalId)
        legacyCloseStream(session.terminalId)
    }

    /// Runs a CLI command for a user action and polls right after so the
    /// resulting topology lands without waiting for the next tick.
    func legacyCommand(_ args: String) {
        Task { [weak self] in
            do {
                _ = try await self?.legacyRun(args: args)
            } catch {
                HerdrController.logger.warning("herdr degraded command failed: \(error.localizedDescription)")
                self?.legacyNotice("command failed: \(error.localizedDescription)")
            }
            await self?.legacyPollOnce()
        }
    }
}
