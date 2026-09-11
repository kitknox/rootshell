import Foundation

extension HerdrController {
    /// This tab's focused pane owns its title even when another tab/workspace
    /// has herdr's global focus. Metadata is only a seed for live pane titles.
    func refreshTitle(of tab: TabModel) {
        guard let tabId = tab.herdrTabId, let info = tabInfos[tabId] else { return }
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
            title = view.herdrTitleState.resolvedTitle(override: view.userOverrideTitle, fallback: info.label)
        } else {
            var seed = HerdrPaneTitleState()
            seed.seed(pane?.title ?? pane?.terminal_title)
            title = seed.resolvedTitle(override: nil, fallback: info.label)
        }
        // Always pass through the coalescer: even an unchanged current title
        // must replace a different title waiting in its trailing publication.
        tab.applyResolvedTitle(title)
    }
}
