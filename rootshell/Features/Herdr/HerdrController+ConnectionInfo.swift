import Foundation

extension HerdrController {
    /// Built from the controller's live model; no server round trip.
    func connectionSnapshot(for request: HerdrConnectionInfo) throws -> HerdrConnectionSnapshot {
        guard !didEnd, request.controllerID == nil || request.controllerID == connectionInfoID else {
            throw HerdrConnectionInfoError.gatewayEnded
        }
        let attachment = localControlAttachment
        let server = HerdrConnectionSnapshot.Server(
            version: serverVersion,
            protocolVersion: controlOpened?.protocol,
            bootID: bootId,
            pid: serverPid ?? attachment.map { Int($0.serverPID) },
            socketPath: attachment?.socketPath,
            startedAt: attachment.flatMap { Self.epochDate($0.serverStartedAt) },
            controlStreamVersion: controlOpened?.capabilities?.terminal_control_stream,
            liveHandoff: controlOpened?.capabilities?.live_handoff)
        let session = HerdrConnectionSnapshot.Session(
            name: sessionName ?? "default",
            workspaces: workspaces.count,
            tabs: tabInfos.count,
            panes: paneInfos.count,
            agents: paneInfos.values.filter { $0.agent != nil }.count,
            createdAt: attachment?.sessionCreatedAt.flatMap(Self.epochDate))
        let endpointOverlay: String?
        switch mode {
        case .raw: endpointOverlay = nil
        case .legacy: endpointOverlay = endpointUnsupported ? "Unsupported" : (endpointActive ? "Active" : "Idle")
        }
        let client = HerdrConnectionSnapshot.Client(
            connectionID: controlOpened?.connection_id,
            isDegraded: mode == .legacy,
            connectedAt: controlOpenedAt,
            isActive: isActive,
            isReconnecting: isReconnectPending,
            reconnectAttempt: reconnectAttempt,
            endpointOverlay: endpointOverlay)
        return HerdrConnectionSnapshot(
            server: server, session: session, client: client,
            tab: request.tabID.flatMap(tabSnapshot),
            pane: request.terminalID.flatMap(paneSnapshot),
            updatedAt: Date())
    }

    private func tabSnapshot(_ tabID: String) -> HerdrConnectionSnapshot.Tab? {
        guard let tab = tabInfos[tabID] else { return nil }
        let workspace = workspaces[tab.workspace_id]
        let size = tabGeometryStates[tabID]?.confirmed
        return HerdrConnectionSnapshot.Tab(
            id: tab.tab_id,
            label: tab.label,
            number: tab.number,
            workspaceLabel: workspace?.label,
            workspaceNumber: workspace?.number,
            panes: tab.pane_count,
            columns: size?.cols,
            rows: size?.rows,
            worktreePath: workspace?.worktree?.checkout_path)
    }

    private func paneSnapshot(_ terminalID: String) -> HerdrConnectionSnapshot.Pane? {
        guard let paneSession = paneSessions[terminalID] else { return nil }
        let paneID = paneSession.paneId
        let info = paneInfos[paneID]
        let rect = info.flatMap { lastLayouts[$0.tab_id] }?.panes.first { $0.pane_id == paneID }?.rect
        return HerdrConnectionSnapshot.Pane(
            id: paneID,
            terminalID: terminalID,
            attachID: paneSession.attachId,
            title: info?.label ?? info?.terminal_title ?? info?.title,
            agent: info?.display_agent ?? info?.agent,
            agentStatus: info?.agent_status,
            workingDirectory: info?.foreground_cwd ?? info?.cwd,
            width: rect?.width,
            height: rect?.height,
            focused: focusedPaneId == paneID)
    }

    /// Helper-reported process times are Unix seconds; reject anything that
    /// cannot be a wall-clock date so a foreign unit never shows as uptime.
    private static func epochDate(_ seconds: UInt64) -> Date? {
        guard seconds >= 946_684_800, seconds <= 253_402_300_799 else { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds))
        return date <= Date().addingTimeInterval(86_400) ? date : nil
    }
}
