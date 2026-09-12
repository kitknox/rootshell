//
//  AgentProjectIdentity.swift
//  rootshell
//
//  What a detected agent is working ON: the project behind its working
//  directory, plus the git branch when we know it.
//
//  Deliberately free of UIKit and of the connection types, so the pure
//  derivation below is compiled and asserted by tests/agent-attention/run.sh
//  the same way the fleet-row parser is.
//

import Foundation

/// A resolved project for one pane. `label` is what the card shows; `path` is
/// the current working directory, while `repositoryRoot` (when probed) is the
/// stable project identity within `hostKey`.
nonisolated struct AgentProjectIdentity: Equatable, Sendable {

    /// Where the directory came from. Ordered by trust: a lower-trust source
    /// never overwrites a higher-trust one for the same pane.
    enum Source: Int, Equatable, Sendable, Comparable {
        /// The shell reported it (OSC 7). Free, pushed, always accepted.
        case osc7 = 1
        /// The multiplexer reported it out-of-band.
        case tmux = 2
        /// A command we ran on the host reported it.
        case probe = 3
        /// herdr's server reported this exact pane's foreground directory.
        /// Unlike a process-tree probe, this is tied to the pane's identity.
        case herdr = 4

        static func < (lhs: Source, rhs: Source) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Which machine `path` lives on: `user@host:port` for a remote pane,
    /// `"local"` for this device. Scopes the cache and keeps identically-named
    /// repositories on different machines apart.
    ///
    /// This device is a host like any other: treating local as "no host" made
    /// local panes fail the probe's host guard, so they could never resolve a
    /// branch.
    var hostKey: String?

    /// Absolute working directory on the host that owns it.
    var path: String

    /// Probed Git work-tree root. Nil when probing is disabled, pending, or
    /// the working directory is not inside a repository.
    var repositoryRoot: String?

    /// Display name — the repository directory when known, else the working
    /// directory's own name.
    var label: String

    /// Current branch, when a lookup has resolved one.
    var branch: String?

    var source: Source

    /// Stable grouping identity: agents in `/repo/src` and `/repo/tests`
    /// resolve to `/repo`; unprobed/non-repository panes fall back to cwd.
    var identityPath: String {
        repositoryRoot ?? path
    }

    /// A current provider directory wins over stale detector state. Retain a
    /// probe's more specific Git root (including submodules) only when it
    /// still describes this directory on the same host.
    static func forGrouping(reported: Self?, detected: Self?) -> Self? {
        guard var reported else { return detected }
        if let detected, detected.hostKey == reported.hostKey,
           let root = detected.repositoryRoot,
           AgentProjectPath.isInsideRepository(reported.path, root: root),
           reported.repositoryRoot.map({ AgentProjectPath.isInsideRepository(root, root: $0) }) ?? true {
            reported.repositoryRoot = root
            reported.label = AgentProjectPath.label(forPath: reported.path, repoRoot: root) ?? reported.label
            reported.branch = detected.branch
        }
        return reported
    }

    init(
        hostKey: String?,
        path: String,
        repositoryRoot: String? = nil,
        label: String,
        branch: String?,
        source: Source
    ) {
        self.hostKey = hostKey
        self.path = AgentProjectPath.normalize(path)
        self.repositoryRoot = repositoryRoot
            .map(AgentProjectPath.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        self.label = label
        self.branch = branch
        self.source = source
    }
}

/// Pure path handling for project labels. Every function here is total: it
/// takes strings and returns strings, with no filesystem access, because the
/// paths it handles belong to other machines.
nonisolated enum AgentProjectPath {

    /// Strips trailing separators and surrounding whitespace. Root stays "/".
    static func normalize(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// The name to show for a working directory.
    ///
    /// `repoRoot` wins when known: an agent working in `repo/src/thing` is
    /// working on `repo`. A git worktree's root is the worktree directory
    /// itself, so worktrees keep their own name with no special handling.
    ///
    /// Returns nil when there is no meaningful name (empty input, or the
    /// filesystem root) so the caller can collapse the line rather than print
    /// a placeholder.
    static func label(forPath path: String, repoRoot: String? = nil) -> String? {
        let candidate = normalize(repoRoot.map(normalize).flatMap { $0.isEmpty ? nil : $0 } ?? path)
        guard !candidate.isEmpty, candidate != "/" else { return nil }
        let name = (candidate as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Collapses `home` to `~`, using the home of the machine that owns the
    /// path rather than this device's.
    ///
    /// Never use `abbreviatingWithTildeInPath` for a remote path: it
    /// abbreviates against the local home, so a remote `/home/example/x` is left
    /// untouched while an unrelated local-looking path could be mangled.
    static func display(path: String, home: String?) -> String {
        let path = normalize(path)
        guard let home = home.map(normalize), !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        // The separator is required: a `home` of /home/example must not match
        // /home/example-other.
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Component-safe containment for carrying a known repository identity
    /// across cwd changes inside that repository.
    static func isInsideRepository(_ path: String, root: String) -> Bool {
        let path = normalize(path)
        let root = normalize(root)
        guard !path.isEmpty, !root.isEmpty else { return false }
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }
}
