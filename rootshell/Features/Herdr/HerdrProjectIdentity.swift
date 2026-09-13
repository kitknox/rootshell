// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

nonisolated enum HerdrProjectIdentity {
    /// Use the actual checkout, not the common repository root: linked
    /// worktrees have the same identity as tmux panes in that checkout.
    static func project(path: String?, workspace: HerdrControl.WorkspaceInfo?, hostKey: String?) -> AgentProjectIdentity? {
        let checkout = absolutePath(workspace?.worktree?.checkout_path)
        guard let cwd = absolutePath(path) ?? checkout else { return nil }
        let root = checkout.flatMap { AgentProjectPath.isInsideRepository(cwd, root: $0) ? $0 : nil }
        return AgentProjectIdentity(
            hostKey: hostKey, path: cwd, repositoryRoot: root,
            label: AgentProjectPath.label(forPath: cwd, repoRoot: root) ?? workspace?.label ?? cwd,
            branch: nil, source: .herdr)
    }
    private static func absolutePath(_ value: String?) -> String? {
        value.flatMap { value in
            let path = AgentProjectPath.normalize(value)
            return path.hasPrefix("/") ? path : nil
        }
    }
}
