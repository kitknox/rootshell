//
//  HerdrController+Commands.swift
//  rootshell
//
//  User intent flows back to herdr as socket API requests; the resulting
//  events and layout records reshape the local tabs. Nothing here mutates
//  the local topology directly.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os

extension HerdrController {

    private func send<P: Encodable>(_ method: String, _ params: P) {
        guard let channel else { return }
        Task {
            do {
                try await channel.request(method, params)
            } catch {
                Self.logger.warning("herdr \(method) failed: \(error.localizedDescription)")
            }
        }
    }

    /// The user focused a pane: keep herdr's active pane in sync. Remote
    /// follows and watchdog re-asserts never call this. The stock CLI has
    /// no focus-by-id, so degraded mode leaves herdr's focus alone.
    func requestSelectPane(_ view: Ghostty.TerminalView) {
        guard let binding = view.herdrPaneBinding, isActive, mode == .raw else { return }
        send("pane.focus", HerdrControl.PaneTarget(pane_id: binding.paneId))
    }

    func requestSplit(_ view: Ghostty.TerminalView, horizontal: Bool) {
        guard let binding = view.herdrPaneBinding else { return }
        let direction = horizontal ? "right" : "down"
        if mode == .legacy {
            legacyCommand("pane split \(binding.paneId) --direction \(direction)")
            return
        }
        send("pane.split", HerdrControl.PaneSplitParams(
            target_pane_id: binding.paneId,
            direction: direction
        ))
    }

    func requestClosePane(_ view: Ghostty.TerminalView) {
        guard let binding = view.herdrPaneBinding else { return }
        if mode == .legacy {
            legacyCommand("pane close \(binding.paneId)")
            return
        }
        send("pane.close", HerdrControl.PaneTarget(pane_id: binding.paneId))
    }

    func requestNewTab(inWorkspaceOf tab: TabModel?) {
        let workspaceId = tab?.herdrWorkspaceId
            ?? workspaces.values.first(where: \.focused)?.workspace_id
            ?? workspaces.keys.sorted().first
        guard let workspaceId else { return }
        pendingNewTabSelectionUntil = Date().addingTimeInterval(5)
        if mode == .legacy {
            legacyCommand("tab create --workspace \(workspaceId)")
            return
        }
        send("tab.create", HerdrControl.TabCreateParams(workspace_id: workspaceId))
    }

    func requestCloseTab(_ tab: TabModel) {
        guard let tabId = tab.herdrTabId else { return }
        if mode == .legacy {
            legacyCommand("tab close \(tabId)")
            return
        }
        send("tab.close", HerdrControl.TabTarget(tab_id: tabId))
    }

    func requestRenameTab(_ tab: TabModel, label: String) {
        guard let tabId = tab.herdrTabId else { return }
        if mode == .legacy {
            legacyCommand("tab rename \(tabId) \(LoginShellCommand.singleQuoted(label))")
            return
        }
        send("tab.rename", HerdrControl.TabRenameParams(tab_id: tabId, label: label))
    }

    func requestToggleZoom(_ view: Ghostty.TerminalView) {
        guard let binding = view.herdrPaneBinding else { return }
        if mode == .legacy {
            legacyCommand("pane zoom \(binding.paneId)")
            return
        }
        send("pane.zoom", HerdrControl.PaneZoomParams(pane_id: binding.paneId, mode: "toggle"))
    }

    /// Divider drag: move the divider on the pane's `direction` edge by
    /// `cells`. herdr adds the amount to the ratio of the server split
    /// that owns the divider, so the cells are scaled by that split's
    /// extent from the last layout, not the native split's.
    func requestResize(_ view: Ghostty.TerminalView, direction: String, cells: Int) {
        guard let binding = view.herdrPaneBinding, cells > 0 else { return }
        let amount = serverSplitFraction(paneId: binding.paneId, tabId: binding.tabId, direction: direction, cells: cells)
        guard amount > 0.001 else { return }
        if mode == .legacy {
            legacyCommand("pane resize --pane \(binding.paneId) --direction \(direction) --amount \(String(format: "%.3f", amount))")
            return
        }
        send("pane.resize", HerdrControl.PaneResizeParams(pane_id: binding.paneId, direction: direction, amount: amount))
    }

    /// `cells` as a fraction of the server split whose divider lies on the
    /// pane's `direction` edge; falls back to the tab area when the split
    /// cannot be found.
    private func serverSplitFraction(paneId: String, tabId: String, direction: String, cells: Int) -> Double {
        guard let layout = lastLayouts[tabId] else { return 0 }
        let horizontal = direction == "left" || direction == "right"
        let areaExtent = Double(horizontal ? layout.area.width : layout.area.height)
        guard let pane = layout.panes.first(where: { $0.pane_id == paneId }) else {
            return areaExtent > 0 ? Double(cells) / areaExtent : 0
        }
        let edge: Int
        switch direction {
        case "right": edge = pane.rect.x + pane.rect.width
        case "left": edge = pane.rect.x
        case "down": edge = pane.rect.y + pane.rect.height
        default: edge = pane.rect.y
        }
        let split = layout.splits.first { split in
            guard (split.direction == "right") == horizontal else { return false }
            let extent = Double(horizontal ? split.rect.width : split.rect.height)
            let origin = horizontal ? split.rect.x : split.rect.y
            let divider = origin + Int((extent * split.ratio).rounded())
            guard abs(divider - edge) <= 1 else { return false }
            // The split must span the pane on the other axis.
            if horizontal {
                return pane.rect.y >= split.rect.y && pane.rect.y < split.rect.y + split.rect.height
            }
            return pane.rect.x >= split.rect.x && pane.rect.x < split.rect.x + split.rect.width
        }
        let extent = split.map { Double(horizontal ? $0.rect.width : $0.rect.height) } ?? areaExtent
        return extent > 0 ? Double(cells) / extent : 0
    }

    func requestFocusTab(_ tab: TabModel) {
        guard let tabId = tab.herdrTabId else { return }
        send("tab.focus", HerdrControl.TabTarget(tab_id: tabId))
    }
}
