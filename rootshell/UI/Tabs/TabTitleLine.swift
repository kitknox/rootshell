//
//  TabTitleLine.swift
//  rootshell
//
//  One-line tab identity: roam/tmux badges, agent or program logo, optional
//  attention dot, title, optional ⌘N hint. Shared by the hidden-tab-bar
//  indicator HUD and the tab exposé captions so both render a tab the same way.
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
    var logoSize: CGFloat = 14

    @Setting(Settings.CodingAgents.attentionBadges) private var agentMarksEnabled
    @Setting(Settings.Tabs.programIcons) private var programIconsEnabled

    var body: some View {
        let logoMark = tab.logoMark(agentMarks: agentMarksEnabled, programIcons: programIconsEnabled)
        HStack(spacing: 8) {
            if showsBadges {
                RoamTabBadgeView(roamProtocol: tab.activeRoamProtocol)

                if let tmuxBadge = TmuxTabBadgeResolver.badge(for: tab, allTabs: allTabs),
                   !(logoMark != nil && tmuxBadge.yieldsToAgentLogo) {
                    TmuxTabBadgeView(badge: tmuxBadge, palette: tmuxBadgePalette)
                }

                if let logoMark {
                    AgentBrandMark(mark: logoMark, size: logoSize, tint: textColor)
                }

                if tab.herdrIsControlledElsewhere {
                    HerdrControlledElsewhereBadge()
                }

                if showsAttentionDot, let status = tab.attentionBadge {
                    AttentionStatusDotView(status: status, size: 7)
                }
            }

            Text(tab.title)
                .font(titleFont)
                .foregroundColor(textColor)
                .lineLimit(1)

            if let keyboardShortcut {
                Text(keyboardShortcut)
                    .font(shortcutFont)
                    .foregroundColor(textColor.opacity(0.7))
            }
        }
    }
}
