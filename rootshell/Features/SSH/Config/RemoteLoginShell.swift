//
//  RemoteLoginShell.swift
//  rootshell
//
//  POSIX-sh snippets and quoting for non-interactive SSH exec requests.
//  Dependency-free (Foundation only) so a standalone SwiftPM test package can
//  symlink this file in directly and syntax-check what remote shells parse.
//

import Foundation

/// Shell snippets and quoting helpers shared by every exec-channel command
/// builder (`TrzszConfig.serverCommand()`, `MoshConfig.serverCommand(shell:)`,
/// `SSHConfig`'s tmux/herdr/zmx exec lines, session discovery, ...).
///
/// `sshd` runs an exec-channel command as `$SHELL -c '<command>'` — the
/// client's *login* shell, not a fixed POSIX shell. A bare `VAR=`/`export`/
/// `for` script is only valid syntax to a POSIX-family shell, so anything
/// built here that is not routed through `wrapForLoginShell` will be parsed
/// (and rejected) by fish, csh, and friends before it ever reaches `sh`.
nonisolated enum RemoteLoginShell {
    /// Tool locations for non-interactive SSH exec requests, searched ahead of
    /// the system directories without depending on shell startup files.
    static let toolPathEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "$HOME/go/bin",
        "/usr/local/go/bin"
    ]

    /// Linux-only tool locations, searched after the ones above. Never even
    /// stat'd on Darwin: /home is an autofs trigger there, so each lookup costs
    /// an automountd/opendirectoryd round trip (#391).
    static let linuxPathEntries = [
        "/home/linuxbrew/.linuxbrew/bin",
        "/snap/bin"
    ]

    static let systemPathEntries = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    /// Shell snippet that prepends the entries above that exist on the target,
    /// in order, preserving its existing PATH. Existence is checked once here
    /// so nonexistent directories never reach a child's PATH search.
    static let pathPrefix: String = {
        func words(_ entries: [String]) -> String {
            entries.map { $0.contains("$") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }
        let linux = linuxPathEntries.joined(separator: " ")
        let list = "\(words(toolPathEntries)) $_rsl \(words(systemPathEntries))"
        // Absolute path: the incoming PATH is exactly what this snippet fixes.
        // Darwin always has it; a Linux host without it falls into the Linux branch.
        return "_rsp=; _rsl=; [ \"$(/usr/bin/uname -s 2>/dev/null)\" = Darwin ] || _rsl=\"\(linux)\"; "
            + "for _rsd in \(list); do [ -d \"$_rsd\" ] && _rsp=\"$_rsp$_rsd:\"; done; export PATH=\"$_rsp$PATH\"; "
    }()

    /// Single-quotes `string` for embedding in a POSIX-sh command line,
    /// escaping any embedded single quote as `'"'"'` — close quote, a
    /// double-quoted single quote, reopen quote — rather than the more
    /// familiar `'\''` (close quote, escaped quote, reopen quote).
    ///
    /// `'\''` only round-trips through POSIX shells: it relies on the
    /// *outer* shell treating `\'` inside a single-quoted string as a literal
    /// backslash-then-quote, which is exactly what POSIX quoting rules say
    /// and exactly what fish does not do — fish instead treats `\'` as an
    /// *escaped quote* even inside single quotes. The two readings agree at
    /// one level of nesting (this command is itself embedded once inside
    /// another `sh -c '...'`) but diverge as soon as a second level of `sh -c
    /// '...'` nesting is introduced (e.g. `MoshConfig.serverCommand` wrapping
    /// `moshSessionCommandWithTerm`'s TERM override wrapping
    /// `SSHConfig.zmxExecCommandLine`): fish then rejects the string outright
    /// with `Unsupported use of '='` because it mis-parses where the quoting
    /// ends.
    ///
    /// `'"'"'` contains no backslash, so there is nothing for fish and POSIX
    /// sh to disagree about — both simply see "end single-quoted section,
    /// start double-quoted section containing one quote, end double-quoted
    /// section, start single-quoted section again". That reading is stable
    /// under arbitrary re-nesting, so this idiom is used here even though it
    /// is three bytes longer per embedded quote than `'\''`.
    static func singleQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    /// Wraps a POSIX-sh script so it survives a remote login shell that is not
    /// POSIX. `sshd` runs exec-channel commands as `$SHELL -c '<command>'`, so a
    /// bare `VAR=`/`export`/`for` script is parsed by fish or csh and rejected
    /// before `sh` ever sees it. `sh -c` hands it to a POSIX shell everywhere.
    ///
    /// The `'"'"'` escaping `singleQuoted` produces is understood identically
    /// by sh, bash, zsh AND fish, so nesting this inside another
    /// single-quoted context (or nesting another `sh -c '...'` inside
    /// `script`) round-trips correctly to arbitrary depth.
    static func wrapForLoginShell(_ script: String) -> String {
        "sh -c \(singleQuoted(script))"
    }
}
