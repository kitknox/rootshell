#if !targetEnvironment(macCatalyst)

import Foundation

/// Parses `git <subcommand> [args...]` command strings.
enum GitCommandParser {
    enum ColorMode: Sendable {
        case auto    // Resolved by caller based on context
        case always  // Force color output
        case never   // Strip all ANSI codes
    }

    struct GitCommandConfig: Sendable {
        var subcommand: String
        var args: [String]
        var workingDirectory: String
        var noPager: Bool = false
        var colorMode: ColorMode = .auto
        var sshKeyName: String? = nil
        var forcePassword: Bool = false
        var profileName: String? = nil
    }

    enum ParseResult {
        case success(GitCommandConfig)
        case help
        case error(String)
    }

    /// Parse a git command string into a config.
    static func parse(command: String, workingDirectory: String) -> ParseResult {
        let tokens = tokenize(command)

        guard tokens.count >= 1 else {
            return .error("usage: git <command> [<args>]")
        }

        // First token should be "git"
        guard tokens[0].lowercased() == "git" else {
            return .error("not a git command")
        }

        return parseTokens(Array(tokens.dropFirst()), workingDirectory: workingDirectory)
    }

    /// Parse from pre-split argv tokens (skipping argv[0] which is "git").
    /// Used by the ios_system bridge to avoid lossy string round-trips.
    static func parseArgs(_ args: [String], workingDirectory: String) -> ParseResult {
        return parseTokens(args, workingDirectory: workingDirectory)
    }

    /// Core parsing logic operating on already-split tokens (after "git").
    private static func parseTokens(_ tokens: [String], workingDirectory: String) -> ParseResult {
        var index = 0
        var gitDir: String?
        var workDir = workingDirectory
        var noPager = false
        var colorMode: ColorMode = .auto
        var sshKeyName: String?
        var forcePassword = false
        var profileName: String?
        var forwardedSubcommandOptions: [String] = []

        while index < tokens.count {
            let token = tokens[index]
            if token == "--no-pager" {
                noPager = true
                index += 1
            } else if token == "--color" || token == "--color=always" {
                colorMode = .always
                index += 1
            } else if token == "--color=never" || token == "--no-color" {
                colorMode = .never
                index += 1
            } else if token == "--color=auto" {
                colorMode = .auto
                index += 1
            } else if token == "--progress" || token == "--no-progress" ||
                        token == "-q" || token == "--quiet" {
                // The local-shell router may inject progress control directly
                // after `git` so it can preserve the original quoted command.
                // Forward it to the selected subcommand, where semantics live.
                forwardedSubcommandOptions.append(token)
                index += 1
            } else if token.hasPrefix("--color=") {
                // Unknown value, treat as auto
                colorMode = .auto
                index += 1
            } else if token == "--help" || token == "-h" {
                return .help
            } else if token == "--version" {
                return .success(GitCommandConfig(
                    subcommand: "version",
                    args: [],
                    workingDirectory: workDir
                ))
            } else if token == "-C" && index + 1 < tokens.count {
                workDir = resolveWorkingDirectory(base: workDir, change: tokens[index + 1])
                index += 2
            } else if token.hasPrefix("--git-dir=") {
                gitDir = String(token.dropFirst(10))
                index += 1
            } else if token == "--git-dir" && index + 1 < tokens.count {
                gitDir = tokens[index + 1]
                index += 2
            } else if token == "--ssh-key" && index + 1 < tokens.count {
                sshKeyName = tokens[index + 1]
                index += 2
            } else if token == "--password" {
                forcePassword = true
                index += 1
            } else if token == "--profile" && index + 1 < tokens.count {
                profileName = tokens[index + 1]
                index += 2
            } else if !token.hasPrefix("-") {
                break
            } else {
                index += 1
            }
        }

        guard index < tokens.count else {
            return .help
        }

        let subcommand = tokens[index]
        let args = Array(tokens[(index + 1)...])

        // If --git-dir was provided, pass it as first arg
        var fullArgs = args
        fullArgs.insert(contentsOf: forwardedSubcommandOptions, at: 0)
        if let gitDir {
            fullArgs.insert("--git-dir=\(gitDir)", at: 0)
        }

        return .success(GitCommandConfig(
            subcommand: subcommand,
            args: fullArgs,
            workingDirectory: workDir,
            noPager: noPager,
            colorMode: colorMode,
            sshKeyName: sshKeyName,
            forcePassword: forcePassword,
            profileName: profileName
        ))
    }

    private static func resolveWorkingDirectory(base: String, change: String) -> String {
        let path = NSString(string: change)
        if path.isAbsolutePath {
            return path.standardizingPath
        }

        let combinedPath = NSString(string: base).appendingPathComponent(change)
        return NSString(string: combinedPath).standardizingPath
    }

    /// Tokenize a command string, respecting quotes.
    /// Quote-aware tokenization shared with local-shell Git classification.
    /// Returned values have shell quotes/escapes removed, matching argv.
    nonisolated static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }

            if char == "\\" && !inSingleQuote {
                escaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if char.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}

#endif
