import Foundation

extension HerdrController {
    /// This tab's focused pane owns its title even when another tab/workspace
    /// has herdr's global focus. Metadata is only a seed for live pane titles.
    func refreshTitle(of tab: TabModel) {
        guard let tabId = tab.herdrTabId, let info = tabInfos[tabId] else { return }
        if let name = tabNames.name(for: tabId) {
            tab.applyResolvedTitle(name)
            return
        }
        let layout = lastLayouts[tabId]
        let candidates = [
            tab.focusedTerminal?.herdrPaneBinding?.paneId,
            layout?.focused_pane_id,
            layout?.panes.first?.pane_id,
        ]
        let pane = candidates.compactMap { $0.flatMap { paneInfos[$0] } }
            .first { $0.tab_id == tabId }
            ?? paneInfos.values.filter { $0.tab_id == tabId }
                .min { $0.pane_id < $1.pane_id }
        let title: String
        if let pane, let view = paneViews[pane.terminal_id] {
            title = view.herdrTitleState.resolvedTitle(override: pane.label ?? view.userOverrideTitle, fallback: info.label)
        } else {
            var seed = HerdrPaneTitleState()
            seed.seed(pane?.title ?? pane?.terminal_title)
            title = seed.resolvedTitle(override: pane?.label, fallback: info.label)
        }
        // Always pass through the coalescer: even an unchanged current title
        // must replace a different title waiting in its trailing publication.
        tab.applyResolvedTitle(title)
    }

    func applyEndpointNames(_ value: [String: Any]) {
        guard let boot = value["boot_id"] as? String,
              let records = value["tabs"] as? [[String: Any]] else { return }
        if let previous = nameMetadataBoot, previous != boot { tabNames = HerdrTabNames() }
        nameMetadataBoot = boot
        let names = records.compactMap { record -> (id: String, label: String, custom: Bool)? in
            guard let id = record["tab_id"] as? String,
                  let label = record["label"] as? String,
                  let custom = record["custom_label"] as? Bool else { return nil }
            return (id, label, custom)
        }
        tabNames.applyEndpoint(names)
        for name in names {
            guard let info = tabInfos[name.id] else { continue }
            tabInfos[name.id] = HerdrControl.TabInfo(tab_id: info.tab_id, workspace_id: info.workspace_id,
                number: info.number, label: name.label, focused: info.focused,
                pane_count: info.pane_count, agent_status: info.agent_status)
        }
        for record in value["panes"] as? [[String: Any]] ?? [] {
            guard let id = record["pane_id"] as? String, var pane = paneInfos[id] else { continue }
            pane.label = record["label"] as? String
            paneInfos[id] = pane
            paneViews[pane.terminal_id]?.publishHerdrTitle()
        }
        for tab in tabs.values { refreshTitle(of: tab) }
        publishManagementState()
    }
}
