//
//  Settings+GitDiff.swift
//  rootshell
//
//  Git diff panel keys: how it is shown and what it compares.
//

import Foundation

extension GitDiffScope: SettingValue {}

nonisolated extension Settings {
    enum GitDiff {
        static let presentation = SettingKey(
            "gitDiff.presentation", default: PanelPresentation.overlay, group: .codingAgents,
            configKey: "git-diff-presentation",
            title: String(localized: "Git Diff Presentation", comment: "Setting title"))
        /// The overlay shows only its summary pill.
        static let collapsed = SettingKey(
            "gitDiff.collapsed", default: false, group: .codingAgents, policy: .localByDefault,
            title: String(localized: "Git Diff Summary Only", comment: "Setting title"))
        static let scope = SettingKey(
            "gitDiff.scope", default: GitDiffScope.uncommitted, group: .codingAgents, policy: .localByDefault,
            title: String(localized: "Git Diff Comparison", comment: "Setting title"))
        static let wrapLines = SettingKey(
            "gitDiff.wrapLines", default: true, group: .codingAgents,
            configKey: "git-diff-wrap-lines",
            title: String(localized: "Wrap Diff Lines", comment: "Setting title"))
        static let ignoreWhitespace = SettingKey(
            "gitDiff.ignoreWhitespace", default: false, group: .codingAgents,
            configKey: "git-diff-ignore-whitespace",
            title: String(localized: "Hide Whitespace Changes", comment: "Setting title"))
        static let sidebarWidth = SettingKey(
            "gitDiff.sidebar.width", default: 460.0, group: .codingAgents, policy: .deviceOnly,
            title: String(localized: "Git Diff Sidebar Width", comment: "Setting title"))
        static let hudWidth = SettingKey(
            "gitDiff.hud.width", default: 580.0, group: .codingAgents, policy: .deviceOnly,
            title: String(localized: "Git Diff Overlay Width", comment: "Setting title"))
        static let hudHeight = SettingKey(
            "gitDiff.hud.height", default: 640.0, group: .codingAgents, policy: .deviceOnly,
            title: String(localized: "Git Diff Overlay Height", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            presentation.erased, collapsed.erased, scope.erased, wrapLines.erased, ignoreWhitespace.erased,
            sidebarWidth.erased, hudWidth.erased, hudHeight.erased,
        ]
    }
}
