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
            seed.seed(pane?.terminal_title ?? pane?.title)
            title = seed.resolvedTitle(override: pane?.label, fallback: info.label)
        }
        // Always pass through the coalescer: even an unchanged current title
        // must replace a different title waiting in its trailing publication.
        tab.applyResolvedTitle(title)
    }

    func applyEndpointSnapshot(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            let metadata = try HerdrControl.decoder.decode(HerdrEndpointMetadata.self, from: data)
            if let previous = endpointMetadata, previous.boot_id == metadata.boot_id,
               metadata.revision <= previous.revision { return }
            let topologyChanged = endpointMetadata.map { !metadata.hasSameTopology(as: $0) } ?? true
            endpointMetadata = metadata
            applyEndpointAgentMetadata()
            if topologyChanged {
                legacyTopologyDirty = true
                refreshTopology()
            }
        } catch {
            legacyTopologyDirty = true
            legacyNotice("endpoint metadata: \(error.localizedDescription)")
        }
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

    func applyEndpointAgentMetadata() {
        guard mode == .legacy, let metadata = endpointMetadata else { return }
        var agents: [String: HerdrEndpointMetadata.Agent] = [:]
        for agent in metadata.agents { agents[agent.pane_id] = agent }
        for pane in metadata.panes {
            guard let previous = paneInfos[pane.pane_id], pane.matches(previous) else { continue }
            let info = pane.updatingDirectories(in: previous)
            paneInfos[pane.pane_id] = info
            if let view = paneViews[info.terminal_id] { publishProject(for: info, view: view) }
            if let agent = agents[pane.pane_id], agent.workspace_id == pane.workspace_id,
               agent.tab_id == pane.tab_id {
                if let view = paneViews[info.terminal_id] {
                    view.herdrTitleState.receiveFallback(agent.reportedTitle)
                    view.publishHerdrTitle()
                }
                agentStatusDidChange(agent.report)
            } else {
                paneViews[info.terminal_id]?.herdrTitleState.endFallback()
                paneViews[info.terminal_id]?.seedHerdrTitle(info.terminal_title ?? info.title)
                agentStatusDidChange(.init(pane_id: pane.pane_id, workspace_id: pane.workspace_id,
                    agent_status: "unknown", agent: nil, title: nil, display_agent: nil, state_labels: nil))
            }
        }
    }
}
