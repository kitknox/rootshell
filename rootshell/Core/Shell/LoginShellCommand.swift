//
//  LoginShellCommand.swift
//  rootshell
//
//  POSIX-sh snippets and quoting for handing a command to somebody else's
//  shell — SSH exec-channel requests, the AI agent's local `$SHELL -l -c`
//  wrapper, the VPN tunnel extension, local probe commands. This is unrelated
//  to `ShellInterpreter.swift` and friends elsewhere in this directory, which
//  is this app's *own* POSIX shell implementation, not a helper for talking
//  to one.
//  Dependency-free (Foundation only) so a standalone SwiftPM test package can
//  symlink this file in directly and syntax-check what remote shells parse.
//

import Foundation

/// Shell snippets and quoting helpers shared by every site that builds a
/// command line for a POSIX shell to run and that command line may pass
/// through, or be interpreted directly by, a login shell that is not POSIX
/// (fish, csh, ...). Used by SSH exec-channel command builders
/// (`TrzszConfig.serverCommand()`, `MoshConfig.serverCommand(shell:)`,
/// `SSHConfig`'s tmux/herdr/zmx exec lines, session discovery, ...), the AI
/// agent's local `$SHELL -l -c` wrapper, the VPN tunnel extension, and local
/// probe commands.
///
/// `sshd` runs an exec-channel command as `$SHELL -c '<command>'` — the
/// client's *login* shell, not a fixed POSIX shell. A bare `VAR=`/`export`/
/// `for` script is only valid syntax to a POSIX-family shell, so anything
/// built here that is not routed through `runInPOSIXShell` will be parsed
/// (and rejected) by fish, csh, and friends before it ever reaches `sh`.
nonisolated enum LoginShellCommand {
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

    /// Double-quotes `value` for embedding in a POSIX-sh command line,
    /// backslash-escaping `\`, `"`, `$` and `` ` `` — the four characters
    /// still special inside POSIX double quotes.
    ///
    /// The fish/POSIX divergence documented on `singleQuoted` is specific to
    /// backslash *inside single quotes*: fish reads `\'` as an escaped quote
    /// there, POSIX shells don't. Inside double quotes the two agree on `\\`,
    /// `\"` and `\$`, but not on `` \` ``: fish has no backtick substitution
    /// (it spells that `()`), so it leaves the backslash in place where a
    /// POSIX shell strips it. That is harmless here only because every caller
    /// hands the result to `runInPOSIXShell`, so `sh` — never the login shell
    /// — parses the double-quoted region. Do not emit this into a string a
    /// non-POSIX shell will parse directly.
    static func doubleQuoted(_ value: String) -> String {
        var out = "\""
        for ch in value {
            switch ch {
            case "\"", "\\", "$", "`": out.append("\\"); out.append(ch)
            default: out.append(ch)
            }
        }
        out.append("\"")
        return out
    }

    /// Wraps a POSIX-sh script so it survives a login shell that is not
    /// POSIX. `sshd` runs exec-channel commands as `$SHELL -c '<command>'` —
    /// the remote user's login shell, not a fixed POSIX shell — so a bare
    /// `VAR=`/`export`/`for` script is parsed by fish or csh and rejected
    /// before `sh` ever sees it; the same is true of any other site that
    /// hands a script to somebody's `$SHELL` rather than invoking `sh`
    /// directly. `sh -c` hands it to a POSIX shell everywhere.
    ///
    /// Pass `login: true` for call sites that need the remote user's profile
    /// sourced — e.g. login-shell discovery probes that depend on PATH or
    /// environment set up by `.profile`/`.zprofile` — which get `sh -lc`
    /// instead. Most callers don't need this: it costs a profile read and,
    /// unlike the plain `sh -c` form, its output can include startup-file
    /// noise the caller then has to filter.
    ///
    /// The `'"'"'` escaping `singleQuoted` produces is understood identically
    /// by sh, bash, zsh AND fish, so nesting this inside another
    /// single-quoted context (or nesting another `sh -c '...'` inside
    /// `script`) round-trips correctly to arbitrary depth.
    static func runInPOSIXShell(_ script: String, login: Bool = false) -> String {
        "sh \(login ? "-lc" : "-c") \(singleQuoted(script))"
    }
}
