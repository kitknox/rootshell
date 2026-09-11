// Copyright (c) 2026 Kit Knox / Rootshell LLC

/// Remembers herdr's ordered lists independently of stable public tab numbers.
/// Creation events append until a snapshot or move supplies the complete order.
nonisolated struct HerdrTabOrder {
    private var workspaceTabs: [String: [String]] = [:]

    mutating func reset(to tabs: [HerdrControl.TabInfo]) {
        workspaceTabs = Dictionary(grouping: tabs, by: \.workspace_id)
            .mapValues { $0.map(\.tab_id) }
    }

    mutating func update(workspaceID: String, tabs: [HerdrControl.TabInfo]) {
        workspaceTabs[workspaceID] = tabs
            .filter { $0.workspace_id == workspaceID }
            .map(\.tab_id)
    }

    mutating func append(_ tab: HerdrControl.TabInfo) {
        guard !(workspaceTabs[tab.workspace_id]?.contains(tab.tab_id) ?? false) else { return }
        workspaceTabs[tab.workspace_id, default: []].append(tab.tab_id)
    }

    mutating func prune(to liveIDs: Set<String>) {
        workspaceTabs = workspaceTabs.compactMapValues { ids in
            let live = ids.filter { liveIDs.contains($0) }
            return live.isEmpty ? nil : live
        }
    }

    /// Only live projections participate; unknown tabs retain discovery order.
    func orderedIDs(in tabs: [HerdrControl.TabInfo], workspaceNumbers: [String: Int]) -> [String] {
        let groups = Dictionary(grouping: tabs, by: \.workspace_id)
        return groups.keys.sorted {
            (workspaceNumbers[$0] ?? Int.max, $0) < (workspaceNumbers[$1] ?? Int.max, $1)
        }.flatMap { workspaceID in
            TabOrderRules.applyingPreferredOrder(
                workspaceTabs[workspaceID] ?? [],
                to: groups[workspaceID, default: []].map(\.tab_id)
            )
        }
    }

    /// herdr adjusts the insertion boundary when the source precedes it.
    /// Missing anchors and already-adjacent tabs require no move.
    static func moveParams(
        for tabID: String,
        after anchorID: String,
        in tabs: [HerdrControl.TabInfo]
    ) -> HerdrControl.TabMoveParams? {
        guard tabID != anchorID,
              let tab = tabs.first(where: { $0.tab_id == tabID }) else { return nil }
        let peers = tabs.filter { $0.workspace_id == tab.workspace_id }.map(\.tab_id)
        guard let anchorIndex = peers.firstIndex(of: anchorID),
              let sourceIndex = peers.firstIndex(of: tabID),
              sourceIndex != anchorIndex + 1 else { return nil }
        return HerdrControl.TabMoveParams(tab_id: tabID, insert_index: anchorIndex + 1)
    }
}
