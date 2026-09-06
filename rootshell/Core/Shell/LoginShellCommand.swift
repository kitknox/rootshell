//
//  LoginShellCommand.swift
//  rootshell
//

import Foundation

/// Builds shell commands that can pass through POSIX or fish login shells.
nonisolated enum LoginShellCommand {
    static let toolPathEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "$HOME/go/bin",
        "/usr/local/go/bin"
    ]

    // Avoid /home lookups on Darwin: they trigger autofs (#391).
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

    /// Prepends existing tool and system directories to PATH.
    static let pathPrefix: String = {
        func words(_ entries: [String]) -> String {
            entries.map { $0.contains("$") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }
        let linux = linuxPathEntries.joined(separator: " ")
        let list = "\(words(toolPathEntries)) $_rsl \(words(systemPathEntries))"
        // Use an absolute path because the incoming PATH may be incomplete.
        return "_rsp=; _rsl=; [ \"$(/usr/bin/uname -s 2>/dev/null)\" = Darwin ] || _rsl=\"\(linux)\"; "
            + "for _rsd in \(list); do [ -d \"$_rsd\" ] && _rsp=\"$_rsp$_rsd:\"; done; export PATH=\"$_rsp$PATH\"; "
    }()

    /// Quotes a word for POSIX shells and fish, including nested commands.
    static func singleQuoted(_ string: String) -> String {
        var out = "'"
        for scalar in string.unicodeScalars {
            switch scalar {
            case "'": out += "'\"'\"'"
            // Fish interprets backslashes inside single quotes; both shells agree here.
            case "\\": out += "'\"\\\\\"'"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "'"
    }

    /// Quotes a word for a POSIX shell; use singleQuoted for the outer login shell.
    static func doubleQuoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"", "\\", "$", "`": out.append("\\"); out.unicodeScalars.append(scalar)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
        return out
    }

    /// Runs POSIX syntax independently of the user's login shell.
    /// `login` sources sh's login profile, not the user's fish or zsh profile.
    static func runInPOSIXShell(_ script: String, login: Bool = false) -> String {
        "sh \(login ? "-lc" : "-c") \(singleQuoted(script))"
    }

    /// Applies PATH after login profiles load, then runs the user's shell syntax.
    static func runInLoginShell(_ command: String, shell: String? = nil, prependPATH: Bool = false) -> String {
        func script(for shell: String) -> String {
            guard prependPATH else { return command }
            if (shell as NSString).lastPathComponent == "fish" {
                let pathCommand = "/bin/sh -c " + singleQuoted(pathPrefix + "printf '%s\\0' \"$PATH\"")
                return "set -gx PATH (\(pathCommand) | string split0); " + command
            }
            let pathCommand = "/bin/sh -c " + singleQuoted(pathPrefix + "printf '%s' \"$PATH\"")
            return "export PATH=\"$(\(pathCommand))\"; " + command
        }

        if let shell {
            return "\(singleQuoted(shell)) -l -c \(singleQuoted(script(for: shell)))"
        }
        let executable = "\"${SHELL:-/bin/sh}\""
        guard prependPATH else {
            return runInPOSIXShell("exec \(executable) -l -c \(singleQuoted(command))")
        }
        return runInPOSIXShell(
            "case \(executable) in */fish|fish) exec \(executable) -l -c \(singleQuoted(script(for: "fish"))) ;; "
                + "*) exec \(executable) -l -c \(singleQuoted(script(for: "sh"))) ;; esac"
        )
    }
}
