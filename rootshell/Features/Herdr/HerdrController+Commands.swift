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

    /// Divider drag: grow or shrink the pane by a fraction of its split.
    func requestResize(_ view: Ghostty.TerminalView, direction: String, amount: Double) {
        guard let binding = view.herdrPaneBinding, amount > 0.001 else { return }
        if mode == .legacy {
            legacyCommand("pane resize --pane \(binding.paneId) --direction \(direction) --amount \(String(format: "%.3f", amount))")
            return
        }
        send("pane.resize", HerdrControl.PaneResizeParams(pane_id: binding.paneId, direction: direction, amount: amount))
    }

    func requestFocusTab(_ tab: TabModel) {
        guard let tabId = tab.herdrTabId else { return }
        send("tab.focus", HerdrControl.TabTarget(tab_id: tabId))
    }
}
