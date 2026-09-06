#if !targetEnvironment(macCatalyst)

import Foundation

/// Protocol for all git subcommand implementations.
protocol GitSubcommand: SendableMetatype {
    /// Help text shown when the user passes `-h` or `--help` to this subcommand.
    static var helpText: String { get }

    /// Execute the subcommand.
    /// - Parameters:
    ///   - repo: Open git_repository pointer (nil for commands that don't need one)
    ///   - args: Remaining arguments after the subcommand name
    ///   - cols: Terminal width in columns (for progress bar sizing)
    ///   - output: Output callback for styled terminal text
    /// - Returns: Exit code (0 for success)
    static func run(
        repo: OpaquePointer?,
        args: [String],
        cols: UInt16,
        output: @escaping @Sendable (String) -> Void
    ) throws -> Int32
}

/// Central dispatch table mapping subcommand names to implementations.
enum GitCommandDispatch {
    nonisolated enum RepoRequirement: Sendable {
        case required    // Fail if not in a repo
        case optional    // Try to open, pass nil if not found
        case none        // Don't try to open
    }

    nonisolated struct CommandEntry: Sendable {
        let name: String
        let repoRequirement: RepoRequirement
        let handler: GitSubcommand.Type
        /// Whether `-h` triggers help. False for commands where `-h` has another meaning (e.g. ls-remote).
        let shortHelpFlag: Bool

        init(name: String, repoRequirement: RepoRequirement, handler: GitSubcommand.Type, shortHelpFlag: Bool = true) {
            self.name = name
            self.repoRequirement = repoRequirement
            self.handler = handler
            self.shortHelpFlag = shortHelpFlag
        }
    }

    nonisolated static let commands: [CommandEntry] = [
        CommandEntry(name: "add",          repoRequirement: .required, handler: GitAdd.self),
        CommandEntry(name: "apply",        repoRequirement: .required, handler: GitApply.self),
        CommandEntry(name: "blame",        repoRequirement: .required, handler: GitBlame.self),
        CommandEntry(name: "branch",       repoRequirement: .required, handler: GitBranch.self),
        CommandEntry(name: "cat-file",     repoRequirement: .required, handler: GitCatFile.self),
        CommandEntry(name: "checkout",     repoRequirement: .required, handler: GitCheckout.self),
        CommandEntry(name: "cherry-pick",  repoRequirement: .required, handler: GitCherryPick.self),
        CommandEntry(name: "clean",        repoRequirement: .required, handler: GitClean.self),
        CommandEntry(name: "clone",        repoRequirement: .none,     handler: GitClone.self),
        CommandEntry(name: "commit",       repoRequirement: .required, handler: GitCommit.self),
        CommandEntry(name: "config",       repoRequirement: .optional, handler: GitConfig.self),
        CommandEntry(name: "describe",     repoRequirement: .required, handler: GitDescribe.self),
        CommandEntry(name: "diff",         repoRequirement: .required, handler: GitDiff.self),
        CommandEntry(name: "fetch",        repoRequirement: .required, handler: GitFetch.self),
        CommandEntry(name: "for-each-ref", repoRequirement: .required, handler: GitForEachRef.self),
        CommandEntry(name: "general",      repoRequirement: .optional, handler: GitGeneral.self),
        CommandEntry(name: "index-pack",   repoRequirement: .none,     handler: GitIndexPack.self),
        CommandEntry(name: "init",         repoRequirement: .none,     handler: GitInit.self),
        CommandEntry(name: "log",          repoRequirement: .required, handler: GitLog.self),
        CommandEntry(name: "ls-files",     repoRequirement: .required, handler: GitLsFiles.self),
        CommandEntry(name: "ls-remote",    repoRequirement: .none,     handler: GitLsRemote.self, shortHelpFlag: false),
        CommandEntry(name: "merge",        repoRequirement: .required, handler: GitMerge.self),
        CommandEntry(name: "mv",           repoRequirement: .required, handler: GitMv.self),
        CommandEntry(name: "pull",         repoRequirement: .required, handler: GitPull.self),
        CommandEntry(name: "push",         repoRequirement: .required, handler: GitPush.self),
        CommandEntry(name: "rebase",       repoRequirement: .required, handler: GitRebase.self),
        CommandEntry(name: "reflog",       repoRequirement: .required, handler: GitReflog.self),
        CommandEntry(name: "remote",       repoRequirement: .required, handler: GitRemote.self),
        CommandEntry(name: "reset",        repoRequirement: .required, handler: GitReset.self),
        CommandEntry(name: "rev-list",     repoRequirement: .required, handler: GitRevList.self),
        CommandEntry(name: "rev-parse",    repoRequirement: .required, handler: GitRevParse.self),
        CommandEntry(name: "revert",       repoRequirement: .required, handler: GitRevert.self),
        CommandEntry(name: "rm",           repoRequirement: .required, handler: GitRm.self),
        CommandEntry(name: "show",         repoRequirement: .required, handler: GitShow.self),
        CommandEntry(name: "show-index",   repoRequirement: .none,     handler: GitShowIndex.self),
        CommandEntry(name: "stash",        repoRequirement: .required, handler: GitStash.self),
        CommandEntry(name: "status",       repoRequirement: .required, handler: GitStatus.self),
        CommandEntry(name: "switch",       repoRequirement: .required, handler: GitSwitch.self),
        CommandEntry(name: "tag",          repoRequirement: .required, handler: GitTag.self),
        CommandEntry(name: "worktree",     repoRequirement: .required, handler: GitWorktree.self),
    ]

    nonisolated static func supportsProgress(_ subcommand: String) -> Bool {
        commands.first(where: { $0.name == subcommand })?.handler is GitProgressSubcommand.Type
    }

    /// Look up and run a subcommand.
    /// Throws `GitError.editorNeeded` if the subcommand requires an editor (e.g., `git commit` without `-m`).
    static func run(
        subcommand: String,
        workingDirectory: String,
        args: [String],
        cols: UInt16,
        output: @escaping @Sendable (String) -> Void,
        statusOutput: (@Sendable (String) -> Void)? = nil,
        progressDefault: Bool = true
    ) throws -> Int32 {
        let diagnosticOutput = statusOutput ?? output
        guard let entry = commands.first(where: { $0.name == subcommand }) else {
            diagnosticOutput(GitStyle.fg(GitStyle.errorColor, "git: '\(subcommand)' is not a git command.\r\n"))
            diagnosticOutput("\r\nAvailable commands:\r\n")
            for cmd in commands {
                diagnosticOutput("  \(cmd.name)\r\n")
            }
            return 1
        }

        // Check for help flags before opening the repo so help works outside a repository.
        // Only consider flags before "--" (option terminator) so that
        // `git checkout -- -h` treats `-h` as a pathspec, not a help request.
        let optionArgs = args.prefix(while: { $0 != "--" })
        if optionArgs.contains("--help") || (entry.shortHelpFlag && optionArgs.contains("-h")) {
            output(entry.handler.helpText)
            return 0
        }

        var repo: OpaquePointer?

        switch entry.repoRequirement {
        case .required:
            let result = git_repository_open_ext(&repo, workingDirectory, 0, nil)
            if result != 0 {
                diagnosticOutput(GitError.notARepository.styledDescription)
                return 128
            }
        case .optional:
            let result = git_repository_open_ext(&repo, workingDirectory, 0, nil)
            if result != 0 && result != GIT_ENOTFOUND.rawValue {
                // Propagate real errors (permissions, corrupt .git, etc.);
                // only swallow "no repository found here"
                let lg2err = git_error_last()
                let detail: String
                if let lg2err, let msg = lg2err.pointee.message {
                    detail = String(cString: msg)
                } else {
                    detail = "unknown error"
                }
                diagnosticOutput(GitStyle.fg(GitStyle.errorColor, "fatal: \(detail)\r\n"))
                return 128
            }
        case .none:
            break
        }

        defer {
            if let repo {
                git_repository_free(repo)
            }
        }

        do {
            if let progressCommand = entry.handler as? GitProgressSubcommand.Type {
                return try progressCommand.run(
                    repo: repo,
                    args: args,
                    cols: cols,
                    output: output,
                    statusOutput: diagnosticOutput,
                    progressDefault: progressDefault
                )
            }
            return try entry.handler.run(repo: repo, args: args, cols: cols, output: output)
        } catch let error as GitError {
            // Let editorNeeded propagate to GitCommand for editor launching
            if case .editorNeeded = error { throw error }
            diagnosticOutput(error.styledDescription)
            return 1
        } catch {
            diagnosticOutput(GitStyle.fg(GitStyle.errorColor, "fatal: \(error.localizedDescription)\r\n"))
            return 1
        }
    }
}

#endif
