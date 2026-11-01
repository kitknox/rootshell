//
//  AgentBrandMark.swift
//  rootshell
//
//  The detected agent's product logo, or the pane's shell or program logo,
//  drawn at the trailing edge of the sidebar card's context line, before a
//  plain row's title, and in the top tab's badge area. Decorative, so it
//  stays out of accessibility.
//

import SwiftUI

struct AgentBrandMark: View {
    /// Manifest agent id from `AgentRowState.agentID`; nil on plain
    /// command rows (a failed shell command with no agent).
    let agentID: String?
    var size: CGFloat = 14

    /// Manifest agent id → asset-catalog name.
    ///
    /// Presentation only, deliberately not a manifest field: the manifest
    /// can be replaced at runtime from Documents, so unknown ids must
    /// degrade to no mark rather than to a missing-asset box.
    ///
    /// Codex has no product mark of its own and borrows OpenAI's, but it
    /// gets its own `CodexLogo` rather than reusing `OpenAILogo`: that
    /// asset is an export with ~16% padding baked into its viewBox, which
    /// renders visibly smaller than the other marks at the same frame.
    /// `CodexLogo` is the same artwork cropped to its ink bounds.
    ///
    /// `omp` and `pi` are separate products (oh-my-pi is a fork of pi) and
    /// keep separate marks. `OhMyPiLogo` is oh-my-pi's own icon, letterboxed
    /// into a square viewBox and cropped to its ink bounds for the same
    /// reason `CodexLogo` is.
    private static let assetNames: [String: String] = [
        "agy": "AntigravityLogo",
        "claude": "ClaudeLogo",
        "codex": "CodexLogo",
        "copilot": "CopilotLogo",
        "cursor": "CursorAgentLogo",
        "helix": "HelixLogo",
        "omp": "OhMyPiLogo",
        "opencode": "OpenCodeLogo",
        "pi": "PiLogo",
        "vim": "VimLogo",
    ]

    /// Nil for ids with no mark, so callers can tell whether one will draw.
    static func assetName(for agentID: String?) -> String? {
        agentID.flatMap { assetNames[$0] }
    }

    /// Agent marks first, then `ProgramCatalog` ids for Running cards.
    static func mark(for agentID: String?) -> BrandMark? {
        guard let agentID else { return nil }
        if let asset = assetNames[agentID] { return .asset(asset) }
        return ProgramCatalog.entry(forID: agentID)?.mark
    }

    /// Bypasses the agent-id lookup for callers that already know which
    /// mark they want. The usage footer needs this: its rows are keyed by
    /// provider brand rather than by a detected agent, and oh-my-pi reports
    /// brands that have no manifest agent id at all.
    private var explicitMark: BrandMark?

    /// Colour for monochrome marks and symbols; the top tab passes its title
    /// colour so they follow the tab theme.
    var tint: Color = .secondary

    init(agentID: String?, size: CGFloat = 14) {
        self.agentID = agentID
        self.size = size
        self.explicitMark = nil
    }

    init(assetName: String, size: CGFloat = 14) {
        self.init(mark: .asset(assetName), size: size)
    }

    init(mark: BrandMark, size: CGFloat = 14, tint: Color = .secondary) {
        self.agentID = nil
        self.size = size
        self.explicitMark = mark
        self.tint = tint
    }

    var body: some View {
        switch explicitMark ?? Self.mark(for: agentID) {
        case .asset(let asset):
            Image(asset)
                // Brand fills, not a tint: Claude, Helix and Vim use the same
                // colours in both appearances, the rest ship light/dark variants.
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                // Quiet enough to sit behind the row's text, but no
                // further: `SidebarTabRow` also fades receding agent
                // metadata to 0.72, and the two multiply.
                .opacity(0.85)
                .accessibilityHidden(true)
        case .template(let asset):
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case nil:
            EmptyView()
        }
    }
}

extension TabModel {
    /// The focused pane's agent mark under the agent-badge setting, else its
    /// shell or program mark under its own toggle.
    func logoMark(agentMarks: Bool, programIcons: Bool) -> BrandMark? {
        if agentMarks, let asset = AgentBrandMark.assetName(for: agentID) {
            return .asset(asset)
        }
        guard programIcons else { return nil }
        return (focusedPane ?? splitTree.first)?.presentation.foregroundProgram?.mark
    }
}
