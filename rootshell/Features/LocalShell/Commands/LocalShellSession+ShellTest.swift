#if !targetEnvironment(macCatalyst)

import Foundation

// MARK: - shelltest command

/// `shelltest` runs the shell interpreter conformance suite on-device.
///
/// Usage:
///   shelltest              — pure-interpreter tier (deterministic, no ios_system)
///   shelltest external     — also run cases that exercise real ios_system commands
///   shelltest <id-prefix>  — run only cases whose id starts with the prefix
extension LocalShellSession {

    func handleShellTestCommand(_ command: String) {
        sessionMode = .scriptRunning
        onTitleChange?("shelltest")
        let arguments = command.split(separator: " ").dropFirst().map(String.init)
        commandQueue.async { [weak self] in
            self?.runShellConformanceSuite(arguments: arguments)
        }
    }

    nonisolated private func runShellConformanceSuite(arguments: [String]) {
        guard !hasStopped else { return }
        scriptCancellationToken.reset()

        if arguments.contains("git-progress") {
            var failures = GitProgressSelfTest.run()
            let quotedCommand = "git --no-color clone '/tmp/source  repo' '/tmp/dest  repo'"
            let rewritten = Self.injectGitOptions(["--progress"], into: quotedCommand)
            let expected = "git --progress --no-color clone '/tmp/source  repo' '/tmp/dest  repo'"
            if rewritten != expected {
                failures.append("option injection changed quoted whitespace")
            }
            let classified = GitCommandParser.tokenize("git -C '/tmp/repo with space' fetch")
            if classified != ["git", "-C", "/tmp/repo with space", "fetch"] {
                failures.append("quote-aware Git classification split a global option value")
            }
            for destination in ["destination>archive", "destination|archive"] {
                let quotedOperatorCommand = "git clone source '\(destination)'"
                let quotedOperatorPrepared = Self.preparedGitCommandForIOSSystem(quotedOperatorCommand)
                let quotedOperatorExpected = "git --color=always --progress clone source '\(destination)'"
                if quotedOperatorPrepared != quotedOperatorExpected {
                    failures.append("quoted shell operator disabled Git terminal options")
                }
            }
            for shellOperator in [">", "|"] {
                if !Self.commandContainsUnquotedOutputOperator("git clone source \(shellOperator) archive") {
                    failures.append("unquoted Git output operator was not detected")
                }
            }
            for terminalBoundSuffix in ["< /dev/null", "; echo later", "&", "|| echo failed"] {
                let terminalBoundCommand = "git fetch \(terminalBoundSuffix)"
                let terminalBoundPrepared = Self.preparedGitCommandForIOSSystem(terminalBoundCommand)
                let terminalBoundExpected = "git --color=always --progress fetch \(terminalBoundSuffix)"
                if terminalBoundPrepared != terminalBoundExpected {
                    failures.append("non-output shell operator disabled Git terminal options")
                }
            }
            let succeeded = failures.isEmpty
            let lines: [String]
            if succeeded {
                lines = ["git-progress: all checks passed\n"]
            } else {
                lines = failures.map { "git-progress: FAIL — \($0)\n" }
            }
            for line in lines {
                outputBatcher.enqueue(Data(line.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastCommandSucceeded = succeeded
                self.scriptCommandExitCode = succeeded ? 0 : 1
                self.recoverFromScriptExecution()
            }
            return
        }

        let includeExternal = arguments.contains("external") || arguments.contains("--external")
        let filter = arguments.first { $0 != "external" && $0 != "--external" }

        var hooks: ShellConformanceTest.ExternalHooks?
        if includeExternal {
            hooks = ShellConformanceTest.ExternalHooks(
                executeExternal: { [weak self] cmd in
                    self?.runScriptExternalCommand(cmd) ?? 127
                },
                captureExternal: { [weak self] cmd in
                    self?.captureCommandOutput(cmd) ?? (127, "")
                }
            )
        }

        let summary = ShellConformanceTest.run(
            filter: filter,
            hooks: hooks,
            isCancelled: { [weak self] in
                guard let self else { return true }
                return self.scriptCancellationToken.isCancelled || self.hasStopped
            },
            emit: { [weak self] line in
                guard let self else { return }
                let terminal = line.replacingOccurrences(of: "\n", with: "\r\n")
                self.outputBatcher.enqueue(Data(terminal.utf8))
            }
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = summary.failed == 0 && !summary.aborted
            self.lastCommandSucceeded = ok
            self.scriptCommandExitCode = ok ? 0 : 1
            self.recoverFromScriptExecution()
        }
    }
}

#endif
