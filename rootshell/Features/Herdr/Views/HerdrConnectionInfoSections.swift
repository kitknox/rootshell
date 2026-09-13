import SwiftUI

/// Mirrors TmuxConnectionInfoSections. The snapshot is read from the
/// controller's live model, so refreshes are synchronous and cheap.
struct HerdrConnectionInfoSections: View {
    let request: HerdrConnectionInfo
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: HerdrConnectionSnapshot?
    @State private var errorMessage: String?
    @State private var ended = false
    @State private var refreshRevision = 0
    @State private var resolvedControllerID: UUID?

    private struct RefreshKey: Hashable {
        let active: Bool
        let revision: Int
        let ended: Bool
    }

    var body: some View {
        Group {
            statusSection
            if let snapshot {
                serverSection(snapshot.server)
                sessionSection(snapshot.session)
                clientSection(snapshot.client)
                if request.tabID != nil { tabSection(snapshot) }
            }
        }
    }

    // Attach lifecycle work to one stable section, not to the group of sections.
    private var statusSection: some View {
        Section("herdr Control Mode") {
            if snapshot == nil && errorMessage == nil {
                ProgressView("Loading herdr information…")
                    .themedRow()
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
            if let snapshot {
                row("State", state(snapshot.client))
                HStack {
                    Text(errorMessage == nil ? "Updated" : "Last Updated · Stale")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(snapshot.updatedAt, style: .time)
                }
                .themedRow()
            }
            if errorMessage != nil && !ended {
                Button("Retry") { refreshRevision += 1 }
                    .themedRow()
            }
        }
        .task(id: RefreshKey(active: scenePhase == .active, revision: refreshRevision, ended: ended)) {
            guard scenePhase == .active, !ended else { return }
            while !Task.isCancelled && !ended {
                refresh()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .herdrControlStateDidChange)) { note in
            guard note.object as? UUID == request.gatewayID, !ended else { return }
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .herdrPaneBindingsChanged)) { _ in
            guard !ended else { return }
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .herdrControlModeDidEnd)) { note in
            guard note.object as? UUID == request.gatewayID else { return }
            ended = true
            errorMessage = HerdrConnectionInfoError.gatewayEnded.localizedDescription
        }
    }

    @MainActor
    private func refresh() {
        guard !ended else { return }
        guard let controller = HerdrController.controller(forGateway: request.gatewayID) else {
            errorMessage = HerdrConnectionInfoError.unavailable.localizedDescription
            if resolvedControllerID != nil || request.controllerID != nil { ended = true }
            return
        }
        let expectedID = request.controllerID ?? resolvedControllerID
        guard !controller.didEnd, expectedID == nil || expectedID == controller.connectionInfoID else {
            ended = true
            errorMessage = HerdrConnectionInfoError.gatewayEnded.localizedDescription
            return
        }
        resolvedControllerID = controller.connectionInfoID
        do {
            snapshot = try controller.connectionSnapshot(for: request)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if controller.didEnd { ended = true }
        }
    }

    private func state(_ client: HerdrConnectionSnapshot.Client) -> String {
        if client.isReconnecting {
            return client.reconnectAttempt > 0 ? "Reconnecting (attempt \(client.reconnectAttempt))" : "Reconnecting"
        }
        if !client.isActive { return "Connecting" }
        return client.isDegraded ? "Connected · Degraded" : "Connected"
    }

    private func serverSection(_ server: HerdrConnectionSnapshot.Server) -> some View {
        Section("herdr Server") {
            row("Version", server.version)
            row("Protocol", server.protocolVersion.map { String($0) })
            row("Boot ID", server.bootID)
            row("PID", server.pid.map { String($0) })
            row("Socket", server.socketPath)
            if server.startedAt != nil { ageRow("Uptime", since: server.startedAt) }
            row("Control Stream", server.controlStreamVersion.map { "v\($0)" })
            row("Live Handoff", server.liveHandoff.map { $0 ? "Yes" : "No" })
        }
    }

    private func sessionSection(_ session: HerdrConnectionSnapshot.Session) -> some View {
        Section("herdr Session") {
            row("Name", session.name)
            if session.createdAt != nil { ageRow("Age", since: session.createdAt) }
            row("Workspaces", String(session.workspaces))
            row("Tabs", String(session.tabs))
            row("Panes", String(session.panes))
            row("Agents", String(session.agents))
        }
    }

    private func clientSection(_ client: HerdrConnectionSnapshot.Client) -> some View {
        Section {
            row("Connection ID", client.connectionID.map { String($0) })
            row("Mode", client.isDegraded ? "Degraded (server-rendered)" : "Control Stream")
            ageRow("Connected", since: client.connectedAt)
            row("Endpoint Overlay", client.endpointOverlay)
        } header: {
            Text("herdr Control Client")
        } footer: {
            Text("Connected measures the current control stream. It restarts when the gateway reconnects.")
        }
    }

    private func tabSection(_ snapshot: HerdrConnectionSnapshot) -> some View {
        Section("This herdr Tab") {
            row("Tab ID", request.tabID)
            row("Tab", snapshot.tab.map { "\($0.number): \($0.label)" })
            row("Workspace", snapshot.tab.flatMap { tab in
                tab.workspaceLabel.map { label in
                    tab.workspaceNumber.map { "\($0): \(label)" } ?? label
                }
            })
            row("Panes", snapshot.tab.map { String($0.panes) })
            row("Tab Size", dimensions(snapshot.tab?.columns, snapshot.tab?.rows))
            row("Worktree", snapshot.tab?.worktreePath)
            if request.terminalID != nil {
                row("Pane ID", snapshot.pane?.id)
                row("Terminal ID", request.terminalID)
                row("Attach ID", snapshot.pane?.attachID)
                row("Title", snapshot.pane?.title)
                row("Agent", agentDescription(snapshot.pane))
                row("Working Directory", snapshot.pane?.workingDirectory)
                row("Pane Size", dimensions(snapshot.pane?.width, snapshot.pane?.height))
                row("Focused", snapshot.pane.map { $0.focused ? "Yes" : "No" })
            }
            if snapshot.tab == nil {
                Text("This tab is no longer in the session.")
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
    }

    private func agentDescription(_ pane: HerdrConnectionSnapshot.Pane?) -> String? {
        guard let pane, let agent = pane.agent else { return nil }
        guard let status = pane.agentStatus, !status.isEmpty else { return agent }
        return "\(agent) · \(status)"
    }

    private func dimensions(_ width: Int?, _ height: Int?) -> String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    private func ageRow(_ label: String, since date: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            row(label, date.map { ConnectionInfoSheet.formatDuration(from: $0, to: context.date) })
        }
        .themedRow()
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .themedRow()
    }
}
