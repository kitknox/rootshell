// Copyright (c) 2026 Kit Knox / Rootshell LLC

/// Remembers herdr's ordered lists independently of stable public tab numbers.
/// Creation events append until a snapshot or move supplies the complete order.
nonisolated struct HerdrTabOrder {
    enum Placement {
        case before(String)
        case after(String)

        var anchorID: String {
            switch self {
            case .before(let id), .after(let id): return id
            }
        }
    }

    /// Capture the destination by identity before a request can suspend.
    struct Move {
        let tabID: String
        let workspaceID: String
        let placement: Placement

        init?(tabID: String, workspaceID: String, orderedIDs: [String]) {
            guard orderedIDs.count > 1, let index = orderedIDs.firstIndex(of: tabID) else { return nil }
            self.tabID = tabID
            self.workspaceID = workspaceID
            placement = index > 0 ? .after(orderedIDs[index - 1]) : .before(orderedIDs[index + 1])
        }

        func params(in tabs: [HerdrControl.TabInfo]) -> HerdrControl.TabMoveParams? {
            HerdrTabOrder.moveParams(
                for: tabID, placement: placement,
                in: tabs.filter { $0.workspace_id == workspaceID }
            )
        }

        /// Keep later gestures visible while an earlier move is confirmed.
        func applying(to order: [String]) -> [String] {
            guard tabID != placement.anchorID, order.contains(tabID), order.contains(placement.anchorID) else {
                return order
            }
            var result = order.filter { $0 != tabID }
            guard let anchorIndex = result.firstIndex(of: placement.anchorID) else { return order }
            switch placement {
            case .before: result.insert(tabID, at: anchorIndex)
            case .after: result.insert(tabID, at: anchorIndex + 1)
            }
            return result
        }
    }

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
        moveParams(for: tabID, placement: .after(anchorID), in: tabs)
    }

    static func moveParams(
        for tabID: String,
        placement: Placement,
        in tabs: [HerdrControl.TabInfo]
    ) -> HerdrControl.TabMoveParams? {
        let anchorID = placement.anchorID
        guard tabID != anchorID,
              let tab = tabs.first(where: { $0.tab_id == tabID }) else { return nil }
        let peers = tabs.filter { $0.workspace_id == tab.workspace_id }.map(\.tab_id)
        guard let anchorIndex = peers.firstIndex(of: anchorID),
              let sourceIndex = peers.firstIndex(of: tabID) else { return nil }
        let boundary: Int
        switch placement {
        case .before: boundary = anchorIndex
        case .after: boundary = anchorIndex + 1
        }
        let destination = sourceIndex < boundary ? boundary - 1 : boundary
        guard sourceIndex != destination else { return nil }
        return HerdrControl.TabMoveParams(tab_id: tabID, insert_index: boundary)
    }
}
