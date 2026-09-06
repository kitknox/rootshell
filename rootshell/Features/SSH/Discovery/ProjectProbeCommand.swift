//
//  ProjectProbeCommand.swift
//  rootshell
//
//  Resolves what a coding agent is working on, on the host it is running on:
//  the repository each working directory belongs to, its branch, and the
//  account's home directory (so a remote path can be shown as `~/...` rather
//  than against THIS device's home).
//
//  Modelled on SessionDiscoveryCommand: one nonce-delimited `sh -lc` over a
//  single SSH exec channel, never typed into the user's pane.
//
//  Gated by `AgentAttentionSettings.projectProbesEnabled` at every call site —
//  this runs a command on someone's machine and the user can switch it off.
//

import Foundation

/// One directory's repository facts.
nonisolated struct ProjectProbeRepo: Equatable, Sendable {
    /// Work-tree root. For a git worktree this is the worktree's own
    /// directory, which is what makes worktrees keep their own name.
    var root: String?
    var branch: String?
}

nonisolated struct ProjectProbeResult: Equatable, Sendable {
    /// The host has no `git`. A stable fact, unlike an empty or truncated
    /// response, so the caller can stop asking instead of retrying forever.
    var gitUnavailable = false
    /// `$HOME` on the probed host.
    var home: String?
    /// Working directory of the process carrying this pane's token, when one
    /// was requested and found. The only directory source for a plain SSH
    /// pane whose remote shell does not report one.
    var paneWorkingDirectory: String?
    /// Keyed by the requested path, verbatim.
    var repos: [String: ProjectProbeRepo] = [:]
}

nonisolated enum ProjectProbeCommand {

    /// Field separator. A tab cannot appear in a path emitted by `pwd`-style
    /// reporting in practice, and `git rev-parse` never emits one.
    private static let separator = "\t"

    /// Builds the probe for a set of directories on one host.
    ///
    /// Paths are batched deliberately: several agents on the same host cost
    /// ONE exec channel, not one each. `git` is probed once up front so a box
    /// without it degrades to home-only instead of erroring per path.
    /// - Parameter pathPrefix: shell prologue that widens `PATH` (callers pass
    ///   `SSHConfig.remoteExecPathPrefix`). An exec channel does NOT get the
    ///   interactive shell's PATH, so without this `command -v git` fails on
    ///   any host keeping git in /opt/homebrew, /usr/local or /snap — the
    ///   command still "succeeds", it just silently reports no repository.
    ///   Defaulted so the pure test harness need not link SSHConfig.
    static func command(
        paths: [String],
        paneToken: String? = nil,
        pathPrefix: String = ""
    ) -> (command: String, nonce: String) {
        let built = script(paths: paths, paneToken: paneToken, pathPrefix: pathPrefix)
        return ("sh -lc \(singleQuoted(built.script))", built.nonce)
    }

    /// The inner script, before it is wrapped for `sh -lc`.
    ///
    /// Exposed so tests can syntax-check what the remote shell ACTUALLY parses.
    /// Running `sh -n` against the wrapped command only parses the outer line;
    /// the script is a quoted argument there, so a syntax error inside it —
    /// which is exactly the regression worth guarding — passes cleanly.
    static func script(
        paths: [String],
        paneToken: String? = nil,
        pathPrefix: String = ""
    ) -> (script: String, nonce: String) {
        let nonce = String(UUID().uuidString.prefix(8))

        var script = pathPrefix
        script += "printf '::HOME_\(nonce)::\\n'; printf '%s\\n' \"$HOME\";"

        // Working directory of the process carrying this pane's token. This is
        // the only directory source for a plain SSH pane whose remote shell
        // does not emit OSC 7, which is most of them.
        //
        // Linux exposes the environment at /proc/<pid>/environ (NUL-separated,
        // hence `tr`) and the cwd as a symlink. macOS has neither, so `ps -E`
        // prints the environment inline and `lsof` reports the cwd. Both are
        // restricted to our own processes, which is exactly the scope wanted.
        if let paneToken, !paneToken.isEmpty {
            let needle = singleQuoted("\(TerminalIdentity.paneTokenVariable)=\(paneToken)")
            script += " printf '::CWD_\(nonce)::\\n';"
            script += " _d='';"

            // Linux: match the pane token in a process environment. Exact and
            // cheap where it is available.
            script += " if [ -r /proc/self/environ ]; then"
            script += " for _e in /proc/[0-9]*; do"
            script += " tr '\\0' '\\n' < \"$_e/environ\" 2>/dev/null | grep -qxF \(needle) || continue;"
            script += " _d=$(readlink \"$_e/cwd\" 2>/dev/null) && [ -n \"$_d\" ] && break;"
            script += " done;"
            script += " fi;"

            // Everywhere else (notably macOS, which does NOT expose process
            // environments to ps at all) fall back to the process TREE: this
            // exec channel and the pane's interactive shell are both children
            // of the same connection's sshd, so the pane is identifiable with
            // no environment access. Walk to that shared ancestor, then take
            // the deepest descendant outside our own branch that has a cwd.
            // Everywhere else (notably macOS, which does NOT expose process
            // environments to ps at all) fall back to the process TREE: this
            // exec channel and the pane's interactive shell are both children
            // of the same connection's sshd.
            //
            // The depth of that shared ancestor is NOT fixed. sshd may exec our
            // command directly from the connection process (shell is our
            // sibling) or via a per-session child (shell is a cousin), and on
            // macOS sshd itself is spawned per connection by launchd. So walk
            // UP level by level and, at each ancestor, look for a process
            // outside our own chain that has a cwd. Nearest ancestor first, so
            // the closest relative wins.
            script += " if [ -z \"$_d\" ]; then"
            script += " _chain=\" $$ \"; _a=$$;"
            script += " for _lvl in 1 2 3; do"
            script += " _a=$(ps -o ppid= -p \"$_a\" 2>/dev/null | tr -d ' ');"
            script += " [ -z \"$_a\" ] || [ \"$_a\" = 0 ] || [ \"$_a\" = 1 ] && break;"
            script += " _chain=\"$_chain$_a \";"
            script += " for _k in $(ps -o pid=,ppid= -ax 2>/dev/null"
            script += " | awk -v a=\"$_a\" '$2==a {print $1}'); do"
            script += " case \"$_chain\" in *\" $_k \"*) continue;; esac;"
            script += " for _c in $(ps -o pid=,ppid= -ax 2>/dev/null"
            script += " | awk -v s=\"$_k\" '$2==s {print $1}') \"$_k\"; do"
            script += " _d=$(lsof -a -p \"$_c\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1);"
            script += " [ -n \"$_d\" ] && break;"
            script += " done;"
            script += " [ -n \"$_d\" ] && break;"
            script += " done;"
            script += " [ -n \"$_d\" ] && break;"
            script += " done;"
            script += " fi;"

            script += " [ -n \"$_d\" ] && printf '%s\\n' \"$_d\";"
        }

        script += " printf '::REPOS_\(nonce)::\\n';"
        // Only emit the git block when there is at least one path. `if ...;
        // then fi` with an empty body is a SYNTAX ERROR in sh, and every
        // directory-discovery probe has no paths by definition — so that probe
        // never once ran, it just failed with a non-zero exit that made the
        // transport discard the whole response.
        if !paths.isEmpty {
        // A host with no git is a STABLE condition, not a failed response. Say
        // so explicitly, or the absence of repository lines is indistinguishable
        // from a truncated reply and the caller re-asks forever.
        script += " if ! command -v git >/dev/null 2>&1; then printf '::NOGIT_\(nonce)::\\n'; fi;"
        script += " if command -v git >/dev/null 2>&1; then"
        for path in paths {
            let quoted = singleQuoted(path)
            // TWO separate invocations, each into its own FIXED field.
            //
            // Combining them as `rev-parse --show-toplevel --abbrev-ref HEAD`
            // is not portable: some git versions print the toplevel and ignore
            // the rest of the argument list, so the reply carried a root and no
            // branch. Reading by position among the lines that happened to
            // arrive then made a missing value indistinguishable from a shifted
            // one. Command substitution gives empty fields instead of absent
            // ones, so position always means the same thing.
            script += " printf '%s\(separator)%s\(separator)%s\\n'"
            script += " \(quoted)"
            script += " \"$(git -C \(quoted) rev-parse --show-toplevel 2>/dev/null)\""
            // `symbolic-ref` names the branch and stays SILENT when HEAD is
            // detached, so the short SHA fallback covers that case rather than
            // the card showing nothing. `rev-parse --abbrev-ref HEAD` prints
            // the literal "HEAD" when detached, which is not a name and cannot
            // be told apart from a failure.
            script += " \"$(git -C \(quoted) symbolic-ref --short -q HEAD 2>/dev/null"
            script += " || git -C \(quoted) rev-parse --short HEAD 2>/dev/null)\";"
        }
        script += " fi;"
        }
        script += " printf '::END_\(nonce)::\\n';"
        // Always succeed. A non-zero exit makes Citadel raise CommandFailed
        // and DISCARD the output, so one failing probe step would throw away
        // the sections that did answer. Markers make partial output safe.
        script += " exit 0"

        return (script, nonce)
    }

    /// Quotes a remote path or script for the login shell.
    static func singleQuoted(_ value: String) -> String {
        LoginShellCommand.singleQuoted(value)
    }

    /// Parses the probe output. Tolerant by design: a host missing `git`, a
    /// path that is not a repository, and a truncated response all yield
    /// partial results rather than nothing.
    static func parse(output: String, nonce: String) -> ProjectProbeResult {
        var result = ProjectProbeResult()

        // `isNewline`, never a comparison against "\n": in Swift "\r\n" is a
        // single Character, so searching for "\n" does not match inside it and
        // a CRLF response would parse as one line. Same trap as the tmux pane
        // reply, which shipped with exactly that bug.
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var section: String?
        var homeLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "::NOGIT_\(nonce)::" { result.gitUnavailable = true; continue }
            if trimmed == "::HOME_\(nonce)::" { section = "home"; continue }
            if trimmed == "::CWD_\(nonce)::" { section = "cwd"; continue }
            if trimmed == "::REPOS_\(nonce)::" { section = "repos"; continue }
            if trimmed == "::END_\(nonce)::" { section = nil; continue }

            switch section {
            case "home":
                if !trimmed.isEmpty { homeLines.append(trimmed) }
            case "cwd":
                // First non-empty line wins: the shell prints at most one,
                // but a noisy profile could add more.
                if !trimmed.isEmpty, result.paneWorkingDirectory == nil {
                    result.paneWorkingDirectory = trimmed
                }
            case "repos":
                guard let parsed = parseRepoLine(line) else { continue }
                result.repos[parsed.path] = parsed.repo
            default:
                continue
            }
        }

        result.home = homeLines.first
        return result
    }

    private static func parseRepoLine(_ line: String) -> (path: String, repo: ProjectProbeRepo)? {
        // `<path>\t` alone means the directory is not a repository, which is
        // a real answer worth caching — it stops the path being re-probed.
        // POSITIONAL, never "the non-empty values in order": field 1 is the
        // repository root and field 2 the branch, each empty when git could not
        // answer. Compacting first let a missing root silently promote the
        // branch into its place.
        let fields = line.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let path = fields.first, !path.isEmpty else { return nil }

        var repo = ProjectProbeRepo()
        if fields.count > 1, !fields[1].isEmpty { repo.root = fields[1] }
        if fields.count > 2, !fields[2].isEmpty {
            // A detached HEAD prints "HEAD"; that is not a branch name and
            // showing it would be misleading.
            repo.branch = fields[2] == "HEAD" ? nil : fields[2]
        }
        return (path, repo)
    }
}
