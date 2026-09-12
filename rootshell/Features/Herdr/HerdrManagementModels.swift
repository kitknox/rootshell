// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

extension HerdrControl {
    struct WorkspaceWorktreeInfo: Decodable, Sendable, Equatable {
        let repo_key: String
        let repo_name: String
        let repo_root: String
        let checkout_path: String
        let is_linked_worktree: Bool
    }
    struct WorkspaceRenameParams: Encodable {
        let workspace_id: String
        let label: String
    }
    struct WorkspaceCloseParams: Encodable {
        let workspace_id: String
        var close_group = false
    }
    struct WorkspaceMoveParams: Encodable {
        let workspace_id: String
        let insert_index: Int
    }
    struct WorkspaceMoveBlockParams: Encodable {
        let workspace_ids: [String]
        let before_workspace_id: String?
    }
    struct WorkspaceResult: Decodable { let workspace: WorkspaceInfo }
    struct WorkspaceListResult: Decodable { let workspaces: [WorkspaceInfo] }
    struct TabResult: Decodable { let tab: TabInfo }
    struct PaneResult: Decodable { let pane: PaneInfo }
    struct OKResult: Decodable {}
    struct WorktreeListParams: Encodable {
        let workspace_id: String
        var trust_repository = false
    }
    struct WorktreeCreateParams: Encodable {
        let workspace_id: String
        let branch: String
        var base: String?
        var path: String?
        var label: String?
        var focus = false
        var trust_repository = false
    }
    struct WorktreeOpenParams: Encodable {
        let workspace_id: String
        let path: String
        var focus = false
        var trust_repository = false
    }
    struct WorktreeRemoveParams: Encodable {
        let workspace_id: String
        var force = false
        var trust_repository = false
    }
    struct WorktreeInfo: Decodable, Sendable, Identifiable {
        var id: String { path }
        let path: String
        let branch: String?
        let label: String
        let is_bare: Bool
        let is_detached: Bool
        let is_prunable: Bool
        let is_linked_worktree: Bool
        let open_workspace_id: String?
    }
    struct WorktreeListResult: Decodable { let worktrees: [WorktreeInfo] }
    struct PaneRenameParams: Encodable {
        let pane_id: String
        /// Omitted means clear the server's manual name.
        let label: String?
    }
    struct PaneSwapParams: Encodable {
        let source_pane_id: String
        let target_pane_id: String
    }
    struct PaneSwapResult: Decodable {
        struct Swap: Decodable {
            let changed: Bool
            let reason: String?
        }
        let swap: Swap
    }
    struct PaneMoveParams: Encodable {
        struct Destination: Encodable {
            let type: String
            var tab_id: String?
            var workspace_id: String?
            var split: String?
        }
        let pane_id: String
        let destination: Destination
        var focus = false
    }
    struct PaneMoveResult: Decodable {
        struct Move: Decodable {
            let changed: Bool
            let reason: String?
            let previous_pane_id: String
            let previous_tab_id: String
            let previous_workspace_id: String
            let pane: PaneInfo
            let created_workspace: WorkspaceInfo?
            let created_tab: TabInfo?
        }
        let move_result: Move
    }
}

/// Pure rules shared by overview ordering, menus, and regression checks.
nonisolated enum HerdrWorkspaceRules {
    static func ordered(_ workspaces: [HerdrControl.WorkspaceInfo]) -> [HerdrControl.WorkspaceInfo] {
        workspaces.sorted { ($0.number, $0.workspace_id) < ($1.number, $1.workspace_id) }
    }

    static func group(of id: String, in workspaces: [HerdrControl.WorkspaceInfo]) -> [HerdrControl.WorkspaceInfo] {
        guard let workspace = workspaces.first(where: { $0.workspace_id == id }) else { return [] }
        guard let tree = workspace.worktree, !tree.is_linked_worktree else { return [workspace] }
        let children = ordered(workspaces).filter {
            $0.workspace_id != id && $0.worktree?.repo_key == tree.repo_key
        }
        return [workspace] + children
    }

    static func groups(_ workspaces: [HerdrControl.WorkspaceInfo]) -> [[HerdrControl.WorkspaceInfo]] {
        let sorted = ordered(workspaces)
        let parents = Dictionary(sorted.compactMap { workspace -> (String, String)? in
            guard let tree = workspace.worktree, !tree.is_linked_worktree else { return nil }
            return (tree.repo_key, workspace.workspace_id)
        }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return sorted.compactMap { workspace in
            let root = workspace.worktree.flatMap { parents[$0.repo_key] } ?? workspace.workspace_id
            guard seen.insert(root).inserted else { return nil }
            return group(of: root, in: sorted)
        }
    }
}

/// Endpoint metadata is authoritative; socket-only connections retain known
/// renames and infer only labels distinguishable from positional defaults.
nonisolated struct HerdrTabNames {
    private var explicit: [String: String] = [:]
    private var endpointNames: [String: String] = [:]
    private var endpointTabs = Set<String>()

    mutating func renamed(_ id: String, label: String) {
        explicit[id] = label
        if endpointTabs.contains(id) { endpointNames[id] = label }
    }
    mutating func applyEndpoint(_ tabs: [(id: String, label: String, custom: Bool)]) {
        endpointTabs = Set(tabs.map(\.id))
        endpointNames = Dictionary(tabs.filter(\.custom).map { ($0.id, $0.label) }, uniquingKeysWith: { _, last in last })
        for tab in tabs {
            explicit[tab.id] = tab.custom ? tab.label : nil
        }
    }
    mutating func reconcile(_ tabs: [HerdrControl.TabInfo]) {
        let live = Set(tabs.map(\.tab_id))
        explicit = explicit.filter { live.contains($0.key) }
        for peers in Dictionary(grouping: tabs, by: \.workspace_id).values {
            for (index, tab) in peers.enumerated() where !endpointTabs.contains(tab.tab_id) {
                if explicit[tab.tab_id] == tab.label { continue }
                explicit[tab.tab_id] = tab.label == String(index + 1) ? nil : tab.label
            }
        }
    }
    func name(for id: String) -> String? {
        let name = endpointTabs.contains(id) ? endpointNames[id] : explicit[id]
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
