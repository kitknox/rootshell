//
//  HerdrController+Legacy.swift
//  rootshell
//
//  Fallback control mode uses the vanilla endpoint for frames and input,
//  with `herdr api snapshot` supplying native tab identities. Compatible
//  servers without the endpoint retain the PTY compatibility path below.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

extension HerdrController {

    private static let legacyPollInterval: Duration = .seconds(2)
    // Default arguments are evaluated nonisolated, so this cap must be too.
    private nonisolated static let legacyMaxResponseBytes = 8 * 1024 * 1024

    /// Uses the stock client when control streams are unavailable or fallback
    /// mode was explicitly requested in Debug settings.
    func startLegacyMode(reason: String, forced: Bool = false) {
        guard mode == .raw, !didEnd else { return }
        mode = .legacy
        legacyFallbackForced = forced
        isActive = false
        connectionError = nil
        reconnectAttempt = 0
        Self.logger.info("herdr control: degraded mode (\(reason))")
        let upgradeHint = " Regular herdr supports native text selection with autoscroll; scrollback is less smooth and global scrollback search is unavailable."
        gateway?.writeToGhostty(string:
            "\r\n\u{1b}[33mherdr control mode: \(reason). Running with server-rendered panes.\(upgradeHint)\u{1b}[0m\r\n")
        publishSessionState()
        legacyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.isActive || self.endpoint == nil || self.legacyTopologyDirty
                    || self.endpointMetadata?.needsShellTitleRefresh == true {
                    await self.legacyPollOnce()
                }
                try? await Task.sleep(for: Self.legacyPollInterval)
            }
        }
    }

    func stopLegacyMode() {
        endpointMetadata = nil
        legacyTopologyDirty = true
        for view in paneViews.values { view.herdrTitleState.endFallback() }
        endpointOpening?.cancel()
        endpointOpening = nil
        let previousEndpoint = endpoint
        endpoint = nil
        previousEndpoint?.close()
        for view in paneViews.values { view.herdrEndpointPane?.disconnect() }
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
        try await legacyRun(command: SSHConfig.herdrCommandLine(sessionName: sessionName, args: args, localAttachment: localControlAttachment), method: args)
    }

    /// Preview commands share the gateway's verified namespace, without
    /// attaching a client or changing focus, selection, or terminal geometry.
    func captureFallbackPreview(_ request: MuxTickRequest) async throws -> MuxTickResult {
        let adapter = HerdrExposeAdapter(localAttachment: localControlAttachment,
                                         commandPrefix: SSHConfig.herdrCommandPrefix(sessionName: sessionName, localAttachment: localControlAttachment),
                                         includesAllWorkspaces: true, validatesCaptures: true)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let output = try await legacyRun(
            command: adapter.tickScript(session: sessionName, request: request, nonce: nonce),
            method: "expose capture", timeout: .seconds(5), maxResponseBytes: 512 * 1024,
            allowsTruncation: true
        )
        guard let result = adapter.parseTick(output: String(decoding: output, as: UTF8.self), session: sessionName, nonce: nonce) else {
            throw HerdrChannelError.malformed("herdr preview returned no snapshot")
        }
        return result
    }

    func fallbackPreviewContext(tabIDs: Set<String>) -> HerdrFallbackPreviewFeed.Context? {
        guard mode == .legacy, !didEnd, !legacySuspended,
              !Ghostty.isAppBackgroundedAtomic, !Ghostty.isSecureDrawProhibitedAtomic,
              let gateway, HerdrChannelFactory.canOpen(for: gateway) else { return nil }
        var previews: [MuxTab] = []
        var identities: [String: String] = [:]
        for id in tabIDs.sorted() {
            guard let tab = tabs[id], tab.id != tabsModel.selectedTabID,
                  let layout = lastLayouts[id] else { continue }
            let panes = layout.panes.compactMap { pane -> MuxPane? in
                guard let info = paneInfos[pane.pane_id], info.tab_id == id else { return nil }
                identities[pane.pane_id] = info.terminal_id
                return MuxPane(id: pane.pane_id, rect: MuxCellRect(
                    x: pane.rect.x - layout.area.x, y: pane.rect.y - layout.area.y,
                    width: pane.rect.width, height: pane.rect.height
                ), isActive: false, isPreviewable: true, title: nil)
            }
            previews.append(MuxTab(id: id, index: 0, title: "", isActive: false,
                cols: layout.area.width, rows: layout.area.height, panes: panes, badge: nil))
        }
        return .init(generation: streamGeneration, endpointID: endpoint.map(ObjectIdentifier.init),
                     selectedTabID: tabsModel.selectedTabID, tabs: previews, paneIdentities: identities,
                     attachment: localControlAttachment)
    }

    /// Socket requests stop at the first complete JSON response; nc may keep
    /// its stdin open after herdr replies, so waiting for process exit can hang.
    private func legacyRun(command: String, method: String, input: Data? = nil,
                           timeout: Duration = .seconds(15), maxResponseBytes: Int = legacyMaxResponseBytes,
                           allowsTruncation: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard let gateway else { throw HerdrChannelError.closed }
        let pipe = try await HerdrChannelFactory.open(command: command, on: gateway)
        let limit = maxResponseBytes
        do {
            try Task.checkCancellation()
            let output = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        var output = Data()
                        if let input { try await pipe.write(input) }
                        while let chunk = try await pipe.read(maxBytes: 64 * 1024) {
                            try Task.checkCancellation()
                            output.append(chunk)
                            if output.count > limit {
                                if allowsTruncation { return Data(output.prefix(limit)) }
                                throw HerdrChannelError.malformed("herdr output exceeds \(limit) bytes")
                            }
                            if input != nil,
                               let line = output.split(separator: 0x0A, omittingEmptySubsequences: false)
                                .dropLast().first(where: { $0.first == UInt8(ascii: "{") }) {
                                return Data(line)
                            }
                        }
                        try Task.checkCancellation()
                        return output
                    } onCancel: {
                        Task { await pipe.close() }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw HerdrChannelError.timedOut(method: method)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await pipe.close()
            return output
        } catch {
            await pipe.close()
            throw error
        }
    }

    /// CLI failures are JSON error responses too. Decode them before the
    /// success shape so creation can distinguish a vanished workspace from
    /// an uncertain transport failure.
    func legacyRequest<Result: Decodable>(args: String, as: Result.Type) async throws -> Result {
        let output = try await legacyRun(args: args)
        try Task.checkCancellation()
        return try decodeLegacyResponse(output, method: args, as: Result.self)
    }

    private func decodeLegacyResponse<Result: Decodable>(_ output: Data, method: String, as: Result.Type) throws -> Result {
        guard let line = output.split(separator: 0x0A).last(where: { $0.first == UInt8(ascii: "{") }) else {
            throw HerdrChannelError.malformed("herdr \(method) returned no JSON")
        }
        let data = Data(line)
        if let error = try HerdrControl.decoder.decode(HerdrControl.LineHead.self, from: data).error {
            throw HerdrChannelError.remote(code: error.code, message: error.message)
        }
        return try HerdrControl.decoder.decode(HerdrControl.Response<Result>.self, from: data).result
    }

    /// Stock herdr supports tab.move on its API but has no matching CLI
    /// subcommand. Ask herdr for its resolved socket (including session/env
    /// overrides), then use a one-shot bridge on the gateway's existing host.
    func legacyMoveTab(_ params: HerdrControl.TabMoveParams) async throws -> HerdrControl.TabListResult {
        try await legacyAPIRequest("tab.move", params, as: HerdrControl.TabListResult.self)
    }

    private struct LegacySocketStatus: Decodable {
        struct Server: Decodable {
            let socket: String
            let running: Bool
            let compatible: Bool?
        }
        let server: Server
    }

    func legacyAPIRequest<P: Encodable, R: Decodable>(_ method: String, _ params: P, as: R.Type) async throws -> R {
        let statusOutput = try await legacyRun(args: "status --json")
        guard let start = statusOutput.firstIndex(of: UInt8(ascii: "{")),
              let end = statusOutput.lastIndex(of: UInt8(ascii: "}")), start <= end else {
            throw HerdrChannelError.malformed("herdr status returned no JSON")
        }
        let status = try HerdrControl.decoder.decode(LegacySocketStatus.self, from: Data(statusOutput[start...end])).server
        guard status.running, !status.socket.isEmpty else { throw HerdrChannelError.closed }
        guard status.compatible != false else {
            throw HerdrChannelError.unsupportedServer("herdr client and server protocols do not match")
        }
        // Python is common on Linux hosts; macOS also ships a Unix-socket nc.
        // Choose once, before sending anything: transport failures are never
        // retried through another bridge after an ambiguous write.
        let python = """
        import socket, sys
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(15)
            connection.connect(sys.argv[1])
            connection.sendall(sys.stdin.buffer.readline())
            sys.stdout.buffer.write(connection.makefile('rb').readline(\(Self.legacyMaxResponseBytes + 1)))
        """
        let socket = LoginShellCommand.singleQuoted(status.socket)
        let script = LoginShellCommand.pathPrefix + """
        if command -v python3 >/dev/null 2>&1; then
            exec python3 -c \(LoginShellCommand.singleQuoted(python)) \(socket)
        elif command -v nc >/dev/null 2>&1; then
            exec nc -U \(socket)
        else
            printf '%s\\n' '{"error":{"code":"socket_bridge_unavailable","message":"This herdr action needs python3 or nc with Unix socket support on the host"}}'
        fi
        """
        var request = try JSONEncoder().encode(HerdrControl.Request(
            id: "rootshell:api:\(UUID().uuidString)", method: method, params: params
        ))
        request.append(0x0A)
        let output = try await legacyRun(
            command: LoginShellCommand.runInPOSIXShell(script), method: method, input: request
        )
        return try decodeLegacyResponse(output, method: method, as: R.self)
    }

    func legacyPollOnce() async {
        guard mode == .legacy, !didEnd, !legacySuspended,
              !Ghostty.isAppBackgroundedAtomic,
              let gateway, HerdrChannelFactory.canOpen(for: gateway) else { return }
        guard !legacyPollInFlight else { return }
        legacyPollInFlight = true
        legacyTopologyDirty = true
        defer { legacyPollInFlight = false; legacyReconcileAttaches() }
        let metadataAtStart = endpointMetadata
        let statusRevision = agentStatusRevision
        let generation = streamGeneration
        let orderRevision = tabReorderRevision
        let capturedManagementRevision = managementRevision
        do {
            let output = try await legacyRun(args: "api snapshot")
            guard mode == .legacy, !didEnd, streamGeneration == generation else { return }
            // A poll started before a completed move cannot put its old order
            // back over the response. The next poll reads the saved order.
            guard orderRevision == tabReorderRevision, capturedManagementRevision == managementRevision, !management.isBusy else { return }
            // The reply is one JSON line; tolerate chatter around it.
            guard let line = output.split(separator: 0x0A).last(where: { $0.first == UInt8(ascii: "{") }) else {
                let text = String(decoding: output.prefix(200), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HerdrChannelError.malformed("herdr api snapshot returned no JSON" + (text.isEmpty ? " (empty output)" : ": \(text)"))
            }
            let fingerprint = line.hashValue
            if let error = try HerdrControl.decoder.decode(HerdrControl.LineHead.self, from: Data(line)).error {
                throw HerdrChannelError.remote(code: error.code, message: error.message)
            }
            let snapshot = try HerdrControl.decoder.decode(
                HerdrControl.Response<HerdrControl.SessionSnapshotResult>.self,
                from: Data(line)
            ).result.snapshot
            isActive = true
            connectionError = nil
            legacyTopologyDirty = endpointMetadata.map { latest in
                metadataAtStart.map { !latest.hasSameTopology(as: $0) } ?? true
            } ?? false
            guard fingerprint != legacySnapshotFingerprint else {
                publishSessionState()
                return
            }
            legacySnapshotFingerprint = fingerprint
            applySnapshot(snapshot, preservingAgentUpdatesAfter: statusRevision)
        } catch {
            guard !didEnd, !Task.isCancelled, streamGeneration == generation,
                  tabReorderRevision == orderRevision,
                  capturedManagementRevision == managementRevision, !management.isBusy else { return }
            if refuseUnsupportedVersion(error) { return }
            isActive = false
            connectionError = error.localizedDescription
            publishSessionState()
            Self.logger.warning("herdr degraded poll failed: \(error.localizedDescription)")
            legacyNotice("snapshot poll failed: \(error.localizedDescription)")
        }
    }

    /// Keep diagnostic notices in the log and gateway shell, once per message.
    func legacyNotice(_ message: String) {
        guard !didEnd else { return }
        guard legacyNoticesShown.insert(message).inserted else { return }
        Self.logger.notice("herdr fallback: \(message)")
        gateway?.writeToGhostty(string: "\r\n\u{1b}[33mherdr control mode: \(message)\u{1b}[0m\r\n")
    }

    /// Open panes lazily, then retain visited panes across tab switches so
    /// their screen, selection and server viewport stay ready to return to.
    func legacyReconcileAttaches() {
        guard mode == .legacy, !didEnd else { return }
        if !endpointUnsupported {
            reconcileEndpoint()
            return
        }
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
            paneViews[terminalId]?.endHerdrTitleAttachment()
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
                        terminalId: terminalId,
                        localAttachment: self.localControlAttachment
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
                self.paneViews[terminalId]?.beginHerdrTitleAttachment()
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
            args: "terminal session control \(LoginShellCommand.singleQuoted(paneId)) --takeover --cols \(grid.cols) --rows \(grid.rows)",
            localAttachment: localControlAttachment
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
        if !endpointUnsupported {
            paneViews[session.terminalId]?.herdrEndpointPane?.sendText(String(decoding: data, as: UTF8.self))
            return
        }
        legacyStreams[session.terminalId]?.sendInput(data)
    }

    func legacyGridDidChange(_ session: HerdrPaneSession, rows: Int, cols: Int) {
        guard rows >= 2, cols >= 4 else { return }
        if !endpointUnsupported {
            session.confirmParserGrid(cols: cols, rows: rows)
            paneViews[session.terminalId]?.herdrEndpointPane?.commitPendingFrame()
            reconcileEndpoint()
            return
        }
        legacyGrids[session.terminalId] = (rows, cols)
        if let stream = legacyStreams[session.terminalId] {
            stream.resize(cols: cols, rows: rows)
        } else {
            legacyReconcileAttaches()
        }
    }

    func legacyPaneDidStop(_ session: HerdrPaneSession) {
        paneViews[session.terminalId]?.herdrEndpointPane?.disconnect()
        paneViews[session.terminalId]?.herdrEndpointPane = nil
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
