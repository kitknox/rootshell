import Foundation

/// The session-wide metadata pushed by unmodified herdr 0.9.0. Geometry and
/// terminal IDs still come from the API snapshot when topology changes.
nonisolated struct HerdrEndpointMetadata: Decodable {
    let boot_id: String
    let revision: UInt64
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let agents: [Agent]

    /// Stock shell snapshots omit titles for panes outside the agent list.
    /// Keep the slow API refresh for those panes, including hidden shells.
    var needsShellTitleRefresh: Bool {
        panes.contains { pane in
            !agents.contains { agent in
                agent.pane_id == pane.pane_id && agent.workspace_id == pane.workspace_id
                    && agent.tab_id == pane.tab_id
            }
        }
    }

    struct Workspace: Decodable, Equatable {
        let workspace_id: String
        let number: Int
        let label: String
    }

    struct Tab: Decodable, Equatable {
        let tab_id: String
        let workspace_id: String
        let number: Int
        let zoomed: Bool
    }

    struct Pane: Decodable, Equatable {
        let pane_id: String
        let workspace_id: String
        let tab_id: String
        let cwd: String?
        let foreground_cwd: String?

        func matches(_ info: HerdrControl.PaneInfo) -> Bool {
            pane_id == info.pane_id && workspace_id == info.workspace_id && tab_id == info.tab_id
        }

        func updatingDirectories(in info: HerdrControl.PaneInfo) -> HerdrControl.PaneInfo {
            guard matches(info) else { return info }
            var updated = info
            updated.cwd = cwd
            updated.foreground_cwd = foreground_cwd
            return updated
        }
    }

    struct Agent: Decodable {
        let pane_id: String
        let workspace_id: String
        let tab_id: String
        let agent: String?
        let display_agent: String?
        let title: String?
        let terminal_title: String?
        let terminal_title_stripped: String?
        let agent_status: String
        let state_labels: [[String]]

        var report: HerdrControl.AgentStatusChangedData {
            .init(pane_id: pane_id, workspace_id: workspace_id,
                  agent_status: agent_status, agent: agent, title: title,
                  display_agent: display_agent, state_labels: Dictionary(
                    state_labels.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
                    uniquingKeysWith: { _, latest in latest }))
        }

        // Vanilla deliberately suppresses spinner-only title events. Use its
        // semantic title so a sampled braille glyph does not look frozen.
        var reportedTitle: String? { terminal_title_stripped ?? title ?? terminal_title }
    }

    func report(for info: HerdrControl.PaneInfo) -> HerdrControl.AgentStatusChangedData? {
        guard panes.contains(where: { $0.pane_id == info.pane_id
            && $0.workspace_id == info.workspace_id && $0.tab_id == info.tab_id }) else { return nil }
        if let agent = agents.first(where: { $0.pane_id == info.pane_id
            && $0.workspace_id == info.workspace_id && $0.tab_id == info.tab_id }) { return agent.report }
        return .init(pane_id: info.pane_id, workspace_id: info.workspace_id,
            agent_status: "unknown", agent: nil, title: nil, display_agent: nil, state_labels: nil)
    }

    func hasSameTopology(as other: Self) -> Bool {
        boot_id == other.boot_id && workspaces == other.workspaces
            && tabs == other.tabs && panes.count == other.panes.count
            && zip(panes, other.panes).allSatisfy {
                $0.pane_id == $1.pane_id && $0.workspace_id == $1.workspace_id && $0.tab_id == $1.tab_id
            }
    }
}
