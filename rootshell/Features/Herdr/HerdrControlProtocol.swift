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

    /// Lowest `terminal_control_stream` capability value this client can drive.
    static let requiredStreamProtocol = 1
    /// Preferred stream protocol; version 3 adds independent pane sizing.
    static let preferredStreamProtocol = 3

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
        /// A terminal's automatic reply (DA, CPR, OSC colour...), not a
        /// keystroke: the server forwards it only from the query authority
        /// and never treats it as interaction. Omitted for old servers.
        var auto: Bool?
    }

    struct TabGeometryParams: Encodable {
        let tab_id: String
        let cols: Int
        let rows: Int
        let cell_width_px: Int
        let cell_height_px: Int
        /// rootshell draws its own dividers; herdr tiles the panes exactly.
        var chrome = "none"
        /// false stores this client's size without taking the tab's geometry.
        /// Omitted (nil) for servers that predate ownership; they always claim.
        var claim: Bool?
    }

    struct PaneTerminalSize: Codable, Sendable, Equatable {
        let cols: Int
        let rows: Int
        let cell_width_px: Int
        let cell_height_px: Int

        init(cols: Int, rows: Int, cell_width_px: Int, cell_height_px: Int) {
            self.cols = cols
            self.rows = rows
            self.cell_width_px = cell_width_px
            self.cell_height_px = cell_height_px
        }

        private enum CodingKeys: String, CodingKey { case cols, rows, cell_width_px, cell_height_px }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            cols = try values.decode(Int.self, forKey: .cols)
            rows = try values.decode(Int.self, forKey: .rows)
            cell_width_px = try values.decode(Int.self, forKey: .cell_width_px)
            cell_height_px = try values.decode(Int.self, forKey: .cell_height_px)
            guard (1...65535).contains(cols), (1...65535).contains(rows),
                  (1...65535).contains(cell_width_px), (1...65535).contains(cell_height_px) else {
                throw DecodingError.dataCorruptedError(forKey: .cols, in: values,
                    debugDescription: "Herdr terminal grids and cell metrics must be positive 16-bit values")
            }
        }
    }

    /// A distinct method prevents old servers from silently ignoring pane sizes.
    struct TabPaneGeometryParams: Encodable {
        let geometry: TabGeometryParams
        let panes: [String: PaneTerminalSize]

        func encode(to encoder: Encoder) throws {
            try geometry.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(panes, forKey: .panes)
        }
        private enum CodingKeys: String, CodingKey { case panes }
    }

    struct ClaimGeometryParams: Encodable {
        let tab_id: String
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

    struct LayoutSetSplitRatioParams: Encodable, Sendable, Equatable {
        let tab_id: String
        /// Server tree path: false selects first, true selects second.
        let path: [Bool]
        let ratio: Double
    }

    /// Both layout.export and layout.set_split_ratio return this shape.
    struct LayoutDescriptionResult: Decodable, Sendable {
        let layout: LayoutDescription
    }

    struct LayoutDescription: Decodable, Sendable {
        let workspace_id: String
        let tab_id: String
        let root: ExportedLayoutNode

        func hasSameTopology(as other: Self) -> Bool {
            workspace_id == other.workspace_id && tab_id == other.tab_id
                && root.hasSameTopology(as: other.root)
        }
    }

    /// Use the server's tree, not the tree reconstructed from rectangles:
    /// equivalent pane geometry can have different split paths, and zoom
    /// hides panes from the geometry snapshot.
    indirect enum ExportedLayoutNode: Decodable, Sendable {
        enum Direction: String, Decodable, Sendable {
            case right, down
        }

        case pane(String)
        case split(direction: Direction, ratio: Double, first: Self, second: Self)

        var paneIDs: [String] {
            switch self {
            case .pane(let id): return [id]
            case .split(_, _, let first, let second): return first.paneIDs + second.paneIDs
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, pane_id, direction, ratio, first, second
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(String.self, forKey: .type) {
            case "pane":
                self = .pane(try values.decode(String.self, forKey: .pane_id))
            case "split":
                let ratio = try values.decode(Double.self, forKey: .ratio)
                guard ratio.isFinite, (0...1).contains(ratio) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .ratio, in: values, debugDescription: "Invalid herdr split ratio"
                    )
                }
                self = .split(
                    direction: try values.decode(Direction.self, forKey: .direction), ratio: ratio,
                    first: try values.decode(Self.self, forKey: .first),
                    second: try values.decode(Self.self, forKey: .second)
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: values, debugDescription: "Unknown herdr layout node"
                )
            }
        }

        func hasSameTopology(as other: Self) -> Bool {
            switch (self, other) {
            case (.pane(let a), .pane(let b)):
                return a == b
            case let (.split(a, _, aFirst, aSecond), .split(b, _, bFirst, bSecond)):
                return a == b && aFirst.hasSameTopology(as: bFirst) && aSecond.hasSameTopology(as: bSecond)
            default:
                return false
            }
        }

        func equalizationRequests(tabID: String, path: [Bool] = []) -> [LayoutSetSplitRatioParams] {
            guard case let .split(direction, ratio, first, second) = self else { return [] }
            let a = first.weight(for: direction)
            let b = second.weight(for: direction)
            // Match SplitTree.equalize(), within herdr's existing ratio limits.
            let target = min(0.9, max(0.1, Double(a) / Double(a + b)))
            var requests: [LayoutSetSplitRatioParams] = []
            // The server stores f32 ratios; avoid rewriting equal thirds, etc.
            if abs(ratio - target) > 0.000001 {
                requests.append(.init(tab_id: tabID, path: path, ratio: target))
            }
            requests += first.equalizationRequests(tabID: tabID, path: path + [false])
            requests += second.equalizationRequests(tabID: tabID, path: path + [true])
            return requests
        }

        private func weight(for direction: Direction) -> Int {
            guard case let .split(axis, _, first, second) = self, axis == direction else { return 1 }
            return first.weight(for: direction) + second.weight(for: direction)
        }
    }

    struct WorkspaceTarget: Encodable {
        let workspace_id: String
    }

    struct PaneSplitParams: Encodable {
        let target_pane_id: String
        /// "right" or "down".
        let direction: String
        var focus = true
        /// Start directory for the new pane's shell; nil follows herdr's policy.
        var cwd: String? = nil
    }

    struct TabCreateParams: Encodable {
        let workspace_id: String
        var focus = true
        var cwd: String? = nil
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

    /// Minimal discriminator decoded from every inbound line. Output records
    /// come along with it, so their base64 payload is parsed only once.
    struct LineHead: Decodable {
        let id: String?
        let type: String?
        let event: String?
        let error: ErrorBody?
        let output: OutputRecord?

        private enum CodingKeys: String, CodingKey {
            case id, type, event, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            event = try container.decodeIfPresent(String.self, forKey: .event)
            error = try container.decodeIfPresent(ErrorBody.self, forKey: .error)
            output = type == "terminal.output" ? try? OutputRecord(from: decoder) : nil
        }
    }

    struct Response<Result: Decodable>: Decodable {
        let id: String
        let result: Result
    }

    struct Capabilities: Decodable, Sendable {
        var terminal_control_stream: Int?
        var server_pid: Int?
        var live_handoff: Bool?
        /// Fine-grained control-stream features (protocol 2 servers).
        var control_features: [String]?
    }

    /// Who sizes a tab: a control stream, a herdr shell client, or nobody.
    struct GeometryController: Decodable, Sendable, Equatable {
        /// "control", "client", or "none".
        let kind: String?
        let connection_id: UInt64?
        /// "server" or "none".
        let chrome: String?
    }

    struct ClientIdentity: Decodable, Sendable, Equatable {
        let name: String?
        let version: String?
        let `protocol`: Int?
    }

    struct ControlAttachInfo: Decodable, Sendable, Equatable {
        let attach_id: String
        let terminal_id: String?
        let pane_id: String?
        let geometry: String?
        let answers_queries: Bool?
    }

    struct ControlTabInfo: Decodable, Sendable, Equatable {
        let tab_id: String
        let cols: Int?
        let rows: Int?
        let chrome: String?
        let controller: Bool?
    }

    struct ControlConnection: Decodable, Sendable, Equatable, Identifiable {
        let connection_id: UInt64
        let control_protocol: Int?
        let client: ClientIdentity?
        let attaches: [ControlAttachInfo]?
        let tabs: [ControlTabInfo]?
        var id: UInt64 { connection_id }

        /// "rootshell 1.0.13", "herdr-control", or the connection number.
        var displayLabel: String {
            let name = client?.name?.split(separator: "/").first.map(String.init) ?? client?.name
            guard let name, !name.isEmpty else { return "connection #\(connection_id)" }
            if let version = client?.version, !version.isEmpty { return "\(name) \(version)" }
            return name
        }
    }

    struct ControlListResult: Decodable, Sendable {
        let self_connection_id: UInt64?
        let connections: [ControlConnection]
    }

    struct ControlOpened: Decodable, Sendable {
        let connection_id: UInt64
        let boot_id: String
        let version: String
        let `protocol`: Int
        /// Control-stream protocol the server negotiated for us; absent on protocol 1 servers.
        let control_protocol: Int?
        let capabilities: Capabilities?

        private enum CodingKeys: String, CodingKey {
            case connection_id, boot_id, version, `protocol`, control_protocol, capabilities
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try HerdrVersionRequirement.validate(try? values.decode(String.self, forKey: .version))
            connection_id = try values.decode(UInt64.self, forKey: .connection_id)
            boot_id = try values.decode(String.self, forKey: .boot_id)
            self.protocol = try values.decode(Int.self, forKey: .protocol)
            control_protocol = try values.decodeIfPresent(Int.self, forKey: .control_protocol)
            capabilities = try values.decodeIfPresent(Capabilities.self, forKey: .capabilities)
        }
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

        private enum CodingKeys: String, CodingKey {
            case x, y, width, height
        }

        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let rawX = try values.decode(Int.self, forKey: .x)
            let rawY = try values.decode(Int.self, forKey: .y)
            let rawWidth = try values.decode(Int.self, forKey: .width)
            let rawHeight = try values.decode(Int.self, forKey: .height)

            guard let x = UInt16(exactly: rawX),
                  let y = UInt16(exactly: rawY),
                  let width = UInt16(exactly: rawWidth),
                  let height = UInt16(exactly: rawHeight) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .width,
                    in: values,
                    debugDescription: "Herdr layout rectangles must contain unsigned 16-bit values"
                )
            }

            self.x = Int(x)
            self.y = Int(y)
            self.width = Int(width)
            self.height = Int(height)
        }
    }

    struct LayoutPane: Decodable, Sendable, Equatable {
        let pane_id: String
        let focused: Bool
        let rect: Rect
        var terminal_size: PaneTerminalSize? = nil

        var terminalCols: Int { terminal_size?.cols ?? rect.width }
        var terminalRows: Int { terminal_size?.rows ?? rect.height }
    }

    struct LayoutSplit: Decodable, Sendable, Equatable {
        let id: String
        /// "right" or "down".
        let direction: String
        let ratio: Double
        let rect: Rect

        private enum CodingKeys: String, CodingKey {
            case id, direction, ratio, rect
        }

        init(id: String, direction: String, ratio: Double, rect: Rect) {
            self.id = id
            self.direction = direction
            self.ratio = ratio
            self.rect = rect
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            direction = try values.decode(String.self, forKey: .direction)
            ratio = try values.decode(Double.self, forKey: .ratio)
            rect = try values.decode(Rect.self, forKey: .rect)
            guard direction == "right" || direction == "down",
                  ratio.isFinite, (0...1).contains(ratio) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ratio,
                    in: values,
                    debugDescription: "Herdr layout splits require a right/down direction and a ratio from zero through one"
                )
            }
        }
    }

    struct LayoutSnapshot: Decodable, Sendable, Equatable {
        let workspace_id: String
        let tab_id: String
        let zoomed: Bool
        let area: Rect
        let focused_pane_id: String
        let panes: [LayoutPane]
        let splits: [LayoutSplit]
        /// Present on protocol 2 servers: the tab's real geometry owner.
        var geometry_controller: GeometryController? = nil

        /// A layout that describes the tab as actually sized, not the TUI viewport.
        var carriesRealGeometry: Bool { geometry_controller != nil }

        private enum CodingKeys: String, CodingKey {
            case workspace_id, tab_id, zoomed, area, focused_pane_id, panes, splits, geometry_controller
        }

        init(workspace_id: String, tab_id: String, zoomed: Bool, area: Rect,
             focused_pane_id: String, panes: [LayoutPane], splits: [LayoutSplit],
             geometry_controller: GeometryController? = nil) {
            self.workspace_id = workspace_id
            self.tab_id = tab_id
            self.zoomed = zoomed
            self.area = area
            self.focused_pane_id = focused_pane_id
            self.panes = panes
            self.splits = splits
            self.geometry_controller = geometry_controller
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            workspace_id = try values.decode(String.self, forKey: .workspace_id)
            tab_id = try values.decode(String.self, forKey: .tab_id)
            zoomed = try values.decode(Bool.self, forKey: .zoomed)
            area = try values.decode(Rect.self, forKey: .area)
            focused_pane_id = try values.decode(String.self, forKey: .focused_pane_id)
            panes = try values.decode([LayoutPane].self, forKey: .panes)
            splits = try values.decode([LayoutSplit].self, forKey: .splits)
            geometry_controller = try values.decodeIfPresent(GeometryController.self, forKey: .geometry_controller)

            let paneIDs = panes.map(\.pane_id)
            let splitIDs = splits.map(\.id)
            guard area.width > 0, area.height > 0,
                  Set(paneIDs).count == paneIDs.count,
                  Set(splitIDs).count == splitIDs.count,
                  panes.allSatisfy({ Self.contains($0.rect, in: area) }),
                  splits.allSatisfy({ Self.contains($0.rect, in: area) }),
                  panes.isEmpty || paneIDs.contains(focused_pane_id) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .panes,
                    in: values,
                    debugDescription: "Herdr layout contains invalid, duplicate, or out-of-bounds geometry"
                )
            }
        }

        private static func contains(_ rect: Rect, in area: Rect) -> Bool {
            guard rect.x >= area.x, rect.y >= area.y else { return false }
            // Every component has already been narrowed to UInt16, so these
            // additions cannot approach Swift Int's limit.
            return rect.x + rect.width <= area.x + area.width
                && rect.y + rect.height <= area.y + area.height
        }
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
        var cwd: String?
        var foreground_cwd: String?
        let state_labels: [String: String]?
        var label: String?
        /// Absent from servers that predate it.
        var foreground_process: ForegroundProcess?

        struct ForegroundProcess: Decodable, Sendable, Equatable {
            let name: String
            let argv: [String]?
            /// The pane's own shell holds the foreground: it is at a prompt.
            let is_shell: Bool
        }

        var foregroundProgram: ForegroundProgram? {
            guard let process = foreground_process else { return nil }
            return ForegroundProgram(
                rawName: process.name, arguments: process.argv ?? [],
                isShell: process.is_shell, source: .herdr)
        }

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

        /// Exact filesystem directory reported by herdr (`foreground_cwd` before
        /// shell `cwd`), preserving any trailing whitespace in the directory name.
        var workingDirectoryPath: String? {
            for value in [foreground_cwd, cwd] {
                guard let value, value.hasPrefix("/") else { continue }
                return value
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

        private enum CodingKeys: String, CodingKey {
            case version, `protocol`, focused_workspace_id, focused_tab_id, focused_pane_id
            case workspaces, tabs, panes, layouts, agents
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Validate before decoding topology, including empty sessions and
            // servers whose older snapshot schema is otherwise unreadable.
            version = try HerdrVersionRequirement.validate(try? values.decode(String.self, forKey: .version))
            self.protocol = try values.decode(Int.self, forKey: .protocol)
            focused_workspace_id = try values.decodeIfPresent(String.self, forKey: .focused_workspace_id)
            focused_tab_id = try values.decodeIfPresent(String.self, forKey: .focused_tab_id)
            focused_pane_id = try values.decodeIfPresent(String.self, forKey: .focused_pane_id)
            workspaces = try values.decode([WorkspaceInfo].self, forKey: .workspaces)
            tabs = try values.decode([TabInfo].self, forKey: .tabs)
            panes = try values.decode([PaneInfo].self, forKey: .panes)
            layouts = try values.decode([LayoutSnapshot].self, forKey: .layouts)
            agents = try values.decode([AgentInfo].self, forKey: .agents)

            guard Set(workspaces.map(\.workspace_id)).count == workspaces.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .workspaces,
                    in: values,
                    debugDescription: "Herdr snapshot contains duplicate workspace IDs"
                )
            }
            guard Set(tabs.map(\.tab_id)).count == tabs.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tabs,
                    in: values,
                    debugDescription: "Herdr snapshot contains duplicate tab IDs"
                )
            }
            guard Set(panes.map(\.pane_id)).count == panes.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .panes,
                    in: values,
                    debugDescription: "Herdr snapshot contains duplicate pane IDs"
                )
            }
        }
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

    struct AuthorityRecord: Decodable, Sendable {
        let attach_id: String
        let answers_queries: Bool
    }

    struct EventsGapRecord: Decodable, Sendable {
        let dropped: UInt64?
        let resume_sequence: UInt64?
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

    struct TabGeometryChangedData: Decodable, Sendable {
        let tab_id: String
        let workspace_id: String?
        let geometry_controller: GeometryController?
        let previous: GeometryController?
    }

    struct AgentStatusChangedData: Decodable, Sendable, Equatable {
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
        case authority(AuthorityRecord)
        case eventsGap(EventsGapRecord)
        case tabGeometryChanged(TabGeometryChangedData)
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
        decodeInbound(line, head: try? decoder.decode(LineHead.self, from: line))
    }

    /// Same, for a line whose head the caller already decoded (nil when
    /// that failed).
    static func decodeInbound(_ line: Data, head: LineHead?) -> Inbound? {
        guard let head else {
            return .unknown(String(decoding: line.prefix(120), as: UTF8.self))
        }
        if head.id != nil, head.type == nil, head.event == nil {
            return nil
        }
        if let type = head.type {
            return decodeRecord(type: type, head: head, line: line)
        }
        if let event = head.event {
            return decodeEvent(event: event, line: line)
        }
        return .unknown(String(decoding: line.prefix(120), as: UTF8.self))
    }

    private static func decodeRecord(type: String, head: LineHead, line: Data) -> Inbound {
        switch type {
        case "terminal.output":
            guard let record = head.output,
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
        case "terminal.authority":
            return (try? decoder.decode(AuthorityRecord.self, from: line)).map(Inbound.authority) ?? .unknown(type)
        case "events.gap":
            return (try? decoder.decode(EventsGapRecord.self, from: line)).map(Inbound.eventsGap) ?? .unknown(type)
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
        case "tab_geometry_changed", "tab.geometry_changed":
            return data(TabGeometryChangedData.self).map(Inbound.tabGeometryChanged) ?? .unknown(event)
        case "pane.agent_status_changed", "pane_agent_status_changed":
            return data(AgentStatusChangedData.self).map(Inbound.agentStatusChanged) ?? .unknown(event)
        default:
            return .unknown(event)
        }
    }
}
