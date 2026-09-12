//
//  HerdrControlProtocol.swift
//  rootshell
//
//  Wire types for herdr's socket API as carried by a control stream
//  (`herdr control`): newline JSON requests and responses, pushed event
//  envelopes, and the raw terminal records added by the rootshell fork.
//  Everything here is plain Codable so the channel actor can decode off the
//  main actor.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated enum HerdrControl {

    /// `terminal_control_stream` capability value this client understands.
    static let requiredStreamProtocol = 1

    // MARK: - Requests

    struct Request<Params: Encodable>: Encodable {
        let id: String
        let method: String
        let params: Params
    }

    struct EmptyParams: Encodable {}

    struct AttachParams: Encodable {
        let target: String
        var answer_queries = "client"
        var history_limit_bytes: Int?
        var takeover = false
    }

    struct AttachTarget: Encodable {
        let attach_id: String
    }

    struct InputParams: Encodable {
        let attach_id: String
        let bytes: String
    }

    struct TabGeometryParams: Encodable {
        let tab_id: String
        let cols: Int
        let rows: Int
        let cell_width_px: Int
        let cell_height_px: Int
        /// rootshell draws its own dividers; herdr tiles the panes exactly.
        var chrome = "none"
    }

    struct Subscription: Encodable {
        let type: String
        var pane_id: String?
    }

    struct SubscribeParams: Encodable {
        let subscriptions: [Subscription]
    }

    struct PaneTarget: Encodable {
        let pane_id: String
    }

    struct TabTarget: Encodable {
        let tab_id: String
    }

    struct WorkspaceTarget: Encodable {
        let workspace_id: String
    }

    struct PaneSplitParams: Encodable {
        let target_pane_id: String
        /// "right" or "down".
        let direction: String
        var focus = true
    }

    struct TabCreateParams: Encodable {
        let workspace_id: String
        var focus = true
    }

    struct TabListParams: Encodable {
        let workspace_id: String
    }

    struct TabMoveParams: Encodable {
        let tab_id: String
        /// Zero-based insertion boundary in the list before removing the tab.
        let insert_index: Int
    }

    struct WorkspaceCreateParams: Encodable {
        var focus = true
        var label: String?
        var cwd: String?
    }

    struct TabRenameParams: Encodable {
        let tab_id: String
        let label: String
    }

    struct PaneZoomParams: Encodable {
        let pane_id: String
        /// "toggle", "on", or "off".
        let mode: String
    }

    struct PaneResizeParams: Encodable {
        let pane_id: String
        /// "left", "right", "up", or "down".
        let direction: String
        /// Fraction of the split to move.
        let amount: Double
    }

    // MARK: - Responses and records

    struct ErrorBody: Decodable, Sendable {
        let code: String
        let message: String
    }

    /// Minimal discriminator decoded from every inbound line.
    struct LineHead: Decodable {
        let id: String?
        let type: String?
        let event: String?
        let error: ErrorBody?
    }

    struct Response<Result: Decodable>: Decodable {
        let id: String
        let result: Result
    }

    struct Capabilities: Decodable, Sendable {
        var terminal_control_stream: Int?
        var server_pid: Int?
        var live_handoff: Bool?
    }

    struct ControlOpened: Decodable, Sendable {
        let connection_id: UInt64
        let boot_id: String
        let version: String
        let `protocol`: Int
        let capabilities: Capabilities?
    }

    struct TerminalAttached: Decodable, Sendable {
        let attach_id: String
        let terminal_id: String
        let pane_id: String?
    }

    struct Rect: Decodable, Sendable, Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    struct LayoutPane: Decodable, Sendable, Equatable {
        let pane_id: String
        let focused: Bool
        let rect: Rect
    }

    struct LayoutSplit: Decodable, Sendable, Equatable {
        let id: String
        /// "right" or "down".
        let direction: String
        let ratio: Double
        let rect: Rect
    }

    struct LayoutSnapshot: Decodable, Sendable, Equatable {
        let workspace_id: String
        let tab_id: String
        let zoomed: Bool
        let area: Rect
        let focused_pane_id: String
        let panes: [LayoutPane]
        let splits: [LayoutSplit]
    }

    struct WorkspaceInfo: Decodable, Sendable, Equatable {
        let workspace_id: String
        var label: String
        let number: Int
        var focused: Bool
        var active_tab_id: String
        let agent_status: String
        var tab_count: Int?
        var pane_count: Int?
        var worktree: WorkspaceWorktreeInfo?
    }

    struct TabInfo: Decodable, Sendable {
        let tab_id: String
        let workspace_id: String
        let number: Int
        let label: String
        let focused: Bool
        let pane_count: Int
        let agent_status: String
    }

    struct PaneInfo: Decodable, Sendable {
        let pane_id: String
        let terminal_id: String
        let workspace_id: String
        let tab_id: String
        var focused: Bool
        let agent_status: String
        let agent: String?
        let display_agent: String?
        let title: String?
        let terminal_title: String?
        let cwd: String?
        let foreground_cwd: String?
        let state_labels: [String: String]?
        var label: String?

        /// Prefer the foreground process, falling back to the shell when
        /// the server cannot resolve a usable foreground directory.
        var projectPath: String? {
            for value in [foreground_cwd, cwd] {
                guard let value else { continue }
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("/") { return path }
            }
            return nil
        }
    }

    struct AgentInfo: Decodable, Sendable {
        let pane_id: String
        let terminal_id: String
        let agent: String?
        let name: String?
        let agent_status: String
        let display_agent: String?
        let title: String?
        let state_change_seq: Int?
    }

    struct SessionSnapshot: Decodable, Sendable {
        let version: String
        let `protocol`: Int
        let focused_workspace_id: String?
        let focused_tab_id: String?
        let focused_pane_id: String?
        let workspaces: [WorkspaceInfo]
        let tabs: [TabInfo]
        let panes: [PaneInfo]
        let layouts: [LayoutSnapshot]
        let agents: [AgentInfo]
    }

    struct SessionSnapshotResult: Decodable {
        let snapshot: SessionSnapshot
    }

    struct TabCreatedResult: Decodable {
        /// workspace.create includes the workspace as well as its initial tab.
        let workspace: WorkspaceInfo?
        let tab: TabInfo
        let root_pane: PaneInfo
    }

    struct TabListResult: Decodable {
        /// Server display order; TabInfo.number is a stable public number.
        let tabs: [TabInfo]
    }

    struct TerminalCursor: Decodable, Sendable {
        let x: Int
        let y: Int
        let visible: Bool
        let shape: Int
        /// The next printable wraps to the next row (cursor sits on the
        /// last column after a print). Older servers omit it.
        let pending_wrap: Bool?
        /// The cell under the cursor as styled VT, for re-establishing
        /// `pending_wrap`.
        let pending_wrap_cell: String?
    }

    struct TerminalState: Decodable, Sendable {
        let cols: Int
        let rows: Int
        let title: String?
        let cwd: String?
        let mouse_reporting: Bool?
        let bracketed_paste: Bool?
        let focus_reporting: Bool?
    }

    struct TerminalSnapshot: Decodable, Sendable {
        let seq: UInt64
        /// "primary" or "alternate".
        let active_screen: String
        let primary: String?
        let alternate: String?
        let state_ansi: String
        /// The active pen alone (SGR, hyperlink, protection); older servers
        /// omit it.
        let pen_ansi: String?
        let cursor: TerminalCursor
        let state: TerminalState
        let truncated: Bool
    }

    struct SnapshotRecord: Decodable, Sendable {
        let attach_id: String
        let snapshot: TerminalSnapshot
    }

    struct OutputRecord: Decodable, Sendable {
        let attach_id: String
        let seq: UInt64
        let bytes: String
    }

    struct GapRecord: Decodable, Sendable {
        let attach_id: String
        let seq: UInt64
        let dropped_bytes: UInt64
    }

    struct DetachedRecord: Decodable, Sendable {
        let attach_id: String
        /// "takeover" or "closed".
        let reason: String
    }

    struct TabLayoutRecord: Decodable, Sendable {
        let layout: LayoutSnapshot
    }

    // MARK: - Events

    struct Event<Data: Decodable>: Decodable {
        let event: String
        let data: Data
    }

    struct PaneEventData: Decodable, Sendable {
        let pane: PaneInfo
    }

    struct PaneClosedData: Decodable, Sendable {
        let pane_id: String
        let workspace_id: String
    }

    struct PaneFocusedData: Decodable, Sendable {
        let pane_id: String
        let workspace_id: String
    }

    struct PaneMovedData: Decodable, Sendable {
        let pane: PaneInfo
        let previous_pane_id: String?
        let previous_tab_id: String?
        let previous_workspace_id: String?
    }

    struct TabEventData: Decodable, Sendable {
        let tab: TabInfo
    }

    struct TabClosedData: Decodable, Sendable {
        let tab_id: String
        let workspace_id: String
    }

    struct TabRenamedData: Decodable, Sendable {
        let tab_id: String
        let workspace_id: String
        let label: String
    }

    struct TabFocusedData: Decodable, Sendable {
        let tab_id: String
        let workspace_id: String
    }

    struct TabMovedData: Decodable, Sendable {
        let tab_id: String
        let workspace_id: String
        let tabs: [TabInfo]
    }

    struct WorkspaceEventData: Decodable, Sendable {
        let workspace: WorkspaceInfo
    }

    struct WorkspaceIdData: Decodable, Sendable {
        let workspace_id: String
    }

    struct WorkspaceRenamedData: Decodable, Sendable {
        let workspace_id: String
        let label: String
    }

    struct LayoutUpdatedData: Decodable, Sendable {
        let layout: LayoutSnapshot
    }

    struct AgentStatusChangedData: Decodable, Sendable {
        let pane_id: String
        let workspace_id: String
        let agent_status: String
        let agent: String?
        let title: String?
        let display_agent: String?
        let state_labels: [String: String]?
    }

    /// Records and events the channel delivers to its owner, already decoded.
    enum Inbound: Sendable {
        case opened(ControlOpened)
        case snapshot(SnapshotRecord)
        case output(attachId: String, seq: UInt64, bytes: Data)
        case gap(GapRecord)
        case detached(DetachedRecord)
        case tabLayout(LayoutSnapshot)
        case paneCreated(PaneInfo)
        case paneUpdated(PaneInfo)
        case paneClosed(PaneClosedData)
        case paneFocused(PaneFocusedData)
        case paneMoved(PaneMovedData)
        case paneExited(PaneClosedData)
        case tabCreated(TabInfo)
        case tabClosed(TabClosedData)
        case tabRenamed(TabRenamedData)
        case tabFocused(TabFocusedData)
        case tabMoved(TabMovedData)
        case workspaceCreated(WorkspaceInfo)
        case workspaceUpdated(WorkspaceInfo)
        case workspaceClosed(WorkspaceIdData)
        case workspaceRenamed(WorkspaceRenamedData)
        case workspaceFocused(WorkspaceIdData)
        case workspaceReordered
        case worktreesChanged
        case layoutUpdated(LayoutSnapshot)
        case agentStatusChanged(AgentStatusChangedData)
        case unknown(String)
    }

    /// Subscriptions a control stream needs to mirror topology and agent state.
    static let topologySubscriptions: [Subscription] = [
        "workspace.created", "workspace.updated", "workspace.closed", "workspace.renamed",
        "workspace.moved", "workspace.reordered", "workspace.focused",
        "tab.created", "tab.closed", "tab.renamed", "tab.moved", "tab.focused",
        "pane.created", "pane.updated", "pane.closed", "pane.focused", "pane.moved",
        "pane.exited", "layout.updated",
    ].map { Subscription(type: $0) }

    // MARK: - Decoding

    static let decoder = JSONDecoder()

    /// Decodes a pushed record or event line. Returns nil for response lines
    /// (those carry an `id`), which the channel routes to their request.
    static func decodeInbound(_ line: Data) -> Inbound? {
        guard let head = try? decoder.decode(LineHead.self, from: line) else {
            return .unknown(String(decoding: line.prefix(120), as: UTF8.self))
        }
        if head.id != nil, head.type == nil, head.event == nil {
            return nil
        }
        if let type = head.type {
            return decodeRecord(type: type, line: line)
        }
        if let event = head.event {
            return decodeEvent(event: event, line: line)
        }
        return .unknown(String(decoding: line.prefix(120), as: UTF8.self))
    }

    private static func decodeRecord(type: String, line: Data) -> Inbound {
        switch type {
        case "terminal.output":
            guard let record = try? decoder.decode(OutputRecord.self, from: line),
                  let bytes = Data(base64Encoded: record.bytes) else { return .unknown(type) }
            return .output(attachId: record.attach_id, seq: record.seq, bytes: bytes)
        case "terminal.snapshot":
            return (try? decoder.decode(SnapshotRecord.self, from: line)).map(Inbound.snapshot) ?? .unknown(type)
        case "terminal.gap":
            return (try? decoder.decode(GapRecord.self, from: line)).map(Inbound.gap) ?? .unknown(type)
        case "terminal.detached":
            return (try? decoder.decode(DetachedRecord.self, from: line)).map(Inbound.detached) ?? .unknown(type)
        case "tab.layout":
            return (try? decoder.decode(TabLayoutRecord.self, from: line)).map { .tabLayout($0.layout) } ?? .unknown(type)
        default:
            return .unknown(type)
        }
    }

    private static func decodeEvent(event: String, line: Data) -> Inbound {
        func data<D: Decodable>(_: D.Type) -> D? {
            (try? decoder.decode(Event<D>.self, from: line))?.data
        }
        switch event {
        case "pane_created": return data(PaneEventData.self).map { .paneCreated($0.pane) } ?? .unknown(event)
        case "pane_updated": return data(PaneEventData.self).map { .paneUpdated($0.pane) } ?? .unknown(event)
        case "pane_closed": return data(PaneClosedData.self).map(Inbound.paneClosed) ?? .unknown(event)
        case "pane_exited": return data(PaneClosedData.self).map(Inbound.paneExited) ?? .unknown(event)
        case "pane_focused": return data(PaneFocusedData.self).map(Inbound.paneFocused) ?? .unknown(event)
        case "pane_moved": return data(PaneMovedData.self).map(Inbound.paneMoved) ?? .unknown(event)
        case "tab_created": return data(TabEventData.self).map { .tabCreated($0.tab) } ?? .unknown(event)
        case "tab_closed": return data(TabClosedData.self).map(Inbound.tabClosed) ?? .unknown(event)
        case "tab_renamed": return data(TabRenamedData.self).map(Inbound.tabRenamed) ?? .unknown(event)
        case "tab_focused": return data(TabFocusedData.self).map(Inbound.tabFocused) ?? .unknown(event)
        case "tab_moved": return data(TabMovedData.self).map(Inbound.tabMoved) ?? .unknown(event)
        case "workspace_created": return data(WorkspaceEventData.self).map { .workspaceCreated($0.workspace) } ?? .unknown(event)
        case "workspace_updated", "workspace_metadata_updated":
            return data(WorkspaceEventData.self).map { .workspaceUpdated($0.workspace) } ?? .unknown(event)
        case "workspace_closed": return data(WorkspaceIdData.self).map(Inbound.workspaceClosed) ?? .unknown(event)
        case "workspace_renamed": return data(WorkspaceRenamedData.self).map(Inbound.workspaceRenamed) ?? .unknown(event)
        case "workspace_focused": return data(WorkspaceIdData.self).map(Inbound.workspaceFocused) ?? .unknown(event)
        case "workspace_moved", "workspace_reordered": return .workspaceReordered
        case "worktree_created", "worktree_opened", "worktree_removed": return .worktreesChanged
        case "layout_updated": return data(LayoutUpdatedData.self).map { .layoutUpdated($0.layout) } ?? .unknown(event)
        case "pane.agent_status_changed", "pane_agent_status_changed":
            return data(AgentStatusChangedData.self).map(Inbound.agentStatusChanged) ?? .unknown(event)
        default:
            return .unknown(event)
        }
    }
}
