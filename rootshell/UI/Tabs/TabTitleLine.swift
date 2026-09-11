//
//  TabTitleLine.swift
//  rootshell
//
//  One-line tab identity: roam/tmux badges, optional attention dot, title,
//  optional ⌘N hint. Shared by the hidden-tab-bar indicator HUD and the tab
//  exposé captions so both render a tab the same way.
//

import SwiftUI

struct TabTitleLine: View {
    let tab: TabModel
    let allTabs: [TabModel]
    let tmuxBadgePalette: TmuxTabBadgePalette
    var keyboardShortcut: String?
    var titleFont: Font = .system(size: 16, weight: .semibold)
    var shortcutFont: Font = .system(size: 14, weight: .medium)
    var textColor: Color = .white
    var showsBadges = true
    var showsAttentionDot = false

    var body: some View {
        HStack(spacing: 8) {
            if showsBadges {
                RoamTabBadgeView(roamProtocol: tab.activeRoamProtocol)

                if let tmuxBadge = TmuxTabBadgeResolver.badge(for: tab, allTabs: allTabs) {
                    TmuxTabBadgeView(badge: tmuxBadge, palette: tmuxBadgePalette)
                }

                if showsAttentionDot, let status = tab.attentionBadge {
                    AttentionStatusDotView(status: status, size: 7)
                }
            }

            Text(tab.title)
                .font(titleFont)
                .foregroundColor(textColor)
                .lineLimit(1)

            if let sessionName = muxSessionName, !sessionName.isEmpty {
                Text(sessionName)
                    .font(shortcutFont)
                    .foregroundColor(textColor.opacity(0.65))
                    .lineLimit(1)
                    .accessibilityLabel("Session \(sessionName)")
            }

            if let keyboardShortcut {
                Text(keyboardShortcut)
                    .font(shortcutFont)
                    .foregroundColor(textColor.opacity(0.7))
            }
        }
    }

    /// Prefer the tmux -CC session label; else a raw/passthrough mux name so
    /// detach/reconnect targets stay visible in exposé and title HUDs.
    private var muxSessionName: String? {
        if let name = tab.tmuxSessionName, !name.isEmpty {
            return name
        }
        guard let focused = tab.focusedTerminal else { return nil }
        if let name = focused.rawMultiplexer?.sessionName, !name.isEmpty {
            return name
        }
        if let name = focused.passthroughMultiplexer?.sessionName, !name.isEmpty {
            return name
        }
        return nil
    }
}
