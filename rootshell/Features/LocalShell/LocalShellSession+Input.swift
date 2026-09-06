#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    /// Process input from user
    func processInput(_ text: String) {
        // Handle escape sequences first
        if escapeBuffer.isEmpty && text.hasPrefix("\u{1b}") {
            // Start of escape sequence
            escapeBuffer = text
            checkEscapeSequence()
            return
        } else if !escapeBuffer.isEmpty {
            // If new escape starts while buffer has incomplete sequence, reset
            if text.hasPrefix("\u{1b}") {
                escapeBuffer = text
            } else {
                escapeBuffer += text
            }
            checkEscapeSequence()
            return
        }

        // Regular character processing
        for char in text {
            handleCharacterInput(char)
        }
    }

    /// Handle a single character
    private func handleCharacterInput(_ char: Character) {
        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A:  // Enter/Return
            handleEnter()

        case 0x09:  // Tab
            handleTab()

        case 0x7F, 0x08:  // Backspace/Delete
            handleBackspace()

        case 0x01:  // Ctrl-A (beginning of line)
            handleCtrlA()

        case 0x05:  // Ctrl-E (end of line)
            handleCtrlE()

        case 0x0B:  // Ctrl-K (kill to end)
            handleCtrlK()

        case 0x15:  // Ctrl-U (kill line)
            handleCtrlU()

        case 0x19:  // Ctrl-Y (yank)
            handleCtrlY()

        case 0x17:  // Ctrl-W (delete word backward)
            handleCtrlW()

        case 0x0C:  // Ctrl-L (clear screen)
            handleCtrlL()

        case 0x04:  // Ctrl-D (EOF)
            handleCtrlD()

        case 0x10:  // Ctrl-P (previous in history)
            handleArrowUp()

        case 0x0E:  // Ctrl-N (next in history)
            handleArrowDown()

        case 0x1B:  // ESC - start of escape sequence
            // Buffer it for next input
            escapeBuffer = "\u{1b}"

        default:
            if !char.isNewline && (char == " " || (!char.isWhitespace && scalar >= 0x20 && scalar != 0x7F)) {
                insertCharacter(char)
            }
        }
    }

    /// Check escape sequence buffer for complete sequences
    private func checkEscapeSequence() {
        // Arrow keys: ESC[A (up), ESC[B (down), ESC[C (right), ESC[D (left)
        if escapeBuffer == "\u{1b}[A" {
            handleArrowUp()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[B" {
            handleArrowDown()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[C" {
            handleArrowRight()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[D" {
            handleArrowLeft()
            escapeBuffer = ""
        // SS3 format (application cursor key mode - DECCKM)
        } else if escapeBuffer == "\u{1b}OA" {
            handleArrowUp()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}OB" {
            handleArrowDown()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}OC" {
            handleArrowRight()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}OD" {
            handleArrowLeft()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[H" || escapeBuffer == "\u{1b}[1~" {
            // Home key
            handleCtrlA()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[F" || escapeBuffer == "\u{1b}[4~" {
            // End key
            handleCtrlE()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[3~" {
            // Delete key
            handleDelete()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}b" {
            // ESC+b - word left (Meta-b / CMD+Left)
            handleWordLeft()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}f" {
            // ESC+f - word right (Meta-f / CMD+Right)
            handleWordRight()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}\u{7f}" {
            // ESC+DEL - delete word backward (Option+Delete)
            handleCtrlW()
            escapeBuffer = ""
        } else if escapeBuffer.count >= 3 {
            // Unknown sequence — check if it could still be a valid prefix
            let knownPrefixes = ["\u{1b}[", "\u{1b}O", "\u{1b}b", "\u{1b}f"]
            let couldBeValid = knownPrefixes.contains(where: { escapeBuffer.hasPrefix($0) })
            if !couldBeValid || escapeBuffer.count > 10 {
                escapeBuffer = ""
            }
        }
    }

    // MARK: - Line Editing Handlers

    private func handleEnter() {
        // Stop history navigation
        historyManager.stopNavigation()

        // Reset general completion state
        generalCompletionState = .idle

        // Clear ghost text on command submission
        clearGhostText()

        let line = lineEditor.consume().trimmingCharacters(in: .whitespaces)

        onOutput?(normalizeLineEndings("\n"))

        // Multi-line continuation: accumulate into buffer
        if var buffer = multiLineInputBuffer {
            if line.isEmpty {
                // Empty line in continuation — keep accumulating
                buffer += "\n"
                multiLineInputBuffer = buffer
                onOutput?("> ")
                return
            }
            buffer += "\n" + line
            multiLineInputBuffer = buffer

            // Try parsing the accumulated input
            let tokenizer = ShellTokenizer(source: buffer)
            let parser = ShellParser(tokenizer: tokenizer)
            let result = parser.tryParse()

            switch result {
            case .complete:
                // Full command — execute it
                let fullCommand = buffer
                multiLineInputBuffer = nil
                historyManager.addCommand(fullCommand)
                handleCommandSubmission(fullCommand)
            case .incomplete:
                // Still incomplete — show continuation prompt
                onOutput?("> ")
            case .error(let msg):
                // Genuine syntax error — abort
                multiLineInputBuffer = nil
                onOutput?(normalizeLineEndings("sh: \(msg)\n"))
                displayPrompt()
            }
            return
        }

        if !line.isEmpty {
            // Check if this starts a compound command that might be incomplete
            if ShellParser.isCompoundCommand(line) || lineEndsWithContinuation(line) {
                let tokenizer = ShellTokenizer(source: line)
                let parser = ShellParser(tokenizer: tokenizer)
                let result = parser.tryParse()

                switch result {
                case .complete:
                    // Complete in one line (e.g., `for i in 1 2 3; do echo $i; done`)
                    historyManager.addCommand(line)
                    handleCommandSubmission(line)
                case .incomplete:
                    // Incomplete — start multi-line accumulation
                    multiLineInputBuffer = line
                    onOutput?("> ")
                case .error:
                    // Not a real compound command or syntax error — try normal submission
                    historyManager.addCommand(line)
                    handleCommandSubmission(line)
                }
            } else {
                historyManager.addCommand(line)
                handleCommandSubmission(line)
            }
        } else {
            displayPrompt()
        }
    }

    /// Check if a line ends with a token that implies continuation
    /// (e.g., trailing `\`, `|`, `&&`, `||`, or open keyword without closing).
    private func lineEndsWithContinuation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("\\") { return true }
        if trimmed.hasSuffix("|") { return true }
        if trimmed.hasSuffix("&&") { return true }
        if trimmed.hasSuffix("||") { return true }
        if trimmed.hasSuffix("then") { return true }
        if trimmed.hasSuffix("else") { return true }
        if trimmed.hasSuffix("do") { return true }
        if trimmed.hasSuffix("{") { return true }
        return false
    }

    func handleCommandSubmission(_ command: String, alreadyExpanded: Bool = false, alreadyAliasExpanded: Bool = false) {
        if !alreadyExpanded {
            // Fresh classification per top-level command (settings can change)
            if !alreadyAliasExpanded {
                gitClassificationLock.withLock { gitClassificationCache.removeAll() }
            }

            // Apply transient prompt: replace the full prompt with a simplified version
            if !alreadyAliasExpanded {
                applyTransientPrompt(command: command)
            }

            if !alreadyAliasExpanded,
               let expandedAlias = expandLeadingAlias(in: command) {
                handleCommandSubmission(
                    expandedAlias,
                    alreadyExpanded: false,
                    alreadyAliasExpanded: true
                )
                return
            }

            // ios_system doesn't implement `$(...)`, backticks, `$((...))`,
            // or parameter expansion (`$VAR`, `${VAR}`, `$@`, `$?`, …).
            // Route such commands through the shell interpreter's AST: simple
            // commands are parsed, expanded to argv (with POSIX field splitting
            // and pathname expansion), and each argv entry is single-quoted via
            // `shellEscape` so that substitution output cannot be reparsed as
            // shell syntax by a downstream tokeniser. The rebuilt command is
            // re-entered with `alreadyExpanded: true` so native-routed handlers
            // (ssh, mosh, ping, mtr, git, croc, bssid, whatismyip, …) can still
            // run. Complex commands (pipelines, lists, compound constructs,
            // redirections, pre-command assignments) fall through to the full
            // interpreter, which handles them natively.
            let trimmedForExpansion = command.trimmingCharacters(in: .whitespaces)
            if Self.commandHasShellExpansion(trimmedForExpansion) {
                // Block line-editor input while substitutions run — matches
                // the other interpreter-backed paths (see executeInteractiveScript).
                sessionMode = .scriptRunning
                commandQueue.async { [weak self] in
                    self?.preExpandAndRoute(command)
                }
                return
            }
        }

        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        let lowerCommand = trimmedCommand.lowercased()

        // Route mosh/roam commands to Mosh protocol
        if lowerCommand.hasPrefix("mosh ") || lowerCommand == "mosh" ||
           lowerCommand.hasPrefix("roam ") || lowerCommand == "roam" {
            handleMoshCommand(trimmedCommand)
            return
        }

        // Route tssh/trzsz commands to Trzsz protocol
        if lowerCommand.hasPrefix("tssh ") || lowerCommand == "tssh" ||
           lowerCommand.hasPrefix("trzsz ") || lowerCommand == "trzsz" {
            handleTrzszCommand(trimmedCommand)
            return
        }

        // Route ssh commands to SSH protocol
        if lowerCommand.hasPrefix("ssh ") || lowerCommand == "ssh" {
            handleSSHCommand(trimmedCommand)
            return
        }

        if lowerCommand.hasPrefix("scp ") || lowerCommand == "scp" {
            handleSCPCommand(trimmedCommand)
            return
        }

        if lowerCommand.hasPrefix("sftp ") || lowerCommand == "sftp" {
            handleSFTPCommand(trimmedCommand)
            return
        }

        if lowerCommand.hasPrefix("ssh-copy-id ") || lowerCommand == "ssh-copy-id" {
            handleSSHCopyIDCommand(trimmedCommand)
            return
        }

        // Route ping/ping6 commands to native Swift implementation
        if lowerCommand.hasPrefix("ping6 ") || lowerCommand == "ping6" ||
           lowerCommand.hasPrefix("ping ") || lowerCommand == "ping" {
            handlePingCommand(trimmedCommand)
            return
        }

        // Route croc commands to native Swift implementation (interactive transfer)
        if lowerCommand.hasPrefix("croc ") || lowerCommand == "croc" {
            handleCrocCommand(trimmedCommand)
            return
        }

        // Route mtr/mtr6: interactive → direct terminal, non-interactive → ios_system
        if lowerCommand.hasPrefix("mtr6 ") || lowerCommand == "mtr6" ||
           lowerCommand.hasPrefix("mtr ") || lowerCommand == "mtr" {
            if mtrCommandHasReportFlags(trimmedCommand) {
                // Non-interactive report mode → ios_system handles redirections/pipes
                let truncatedCommand = String(trimmedCommand.prefix(30))
                onTitleChange?(truncatedCommand)
                commandQueue.async { [weak self] in
                    self?.runExternalCommand(command)
                }
            } else {
                // Interactive TUI → direct terminal output
                handleMtrCommand(trimmedCommand)
            }
            return
        }

        // Route traceroute/traceroute6: convert to mtr report mode
        if lowerCommand.hasPrefix("traceroute6 ") || lowerCommand == "traceroute6" ||
           lowerCommand.hasPrefix("traceroute ") || lowerCommand == "traceroute" {
            let mtrEquivalent = convertTracerouteToMtr(trimmedCommand)
            handleMtrCommand(mtrEquivalent)
            return
        }

        // Route git commands: auth flags and editor commit go to native Swift
        // implementation; everything else goes through ios_system for pipe/redirect support
        if lowerCommand.hasPrefix("git ") || lowerCommand == "git" {
            if gitCommandNeedsInterception(trimmedCommand) {
                handleGitCommand(trimmedCommand)
                return
            }
            // Route through ios_system with auto-paging and color injection
            let finalCommand = prepareGitForIOSSystem(trimmedCommand)
            let truncatedCommand = String(finalCommand.prefix(30))
            onTitleChange?(truncatedCommand)
            commandQueue.async { [weak self] in
                self?.runExternalCommand(finalCommand)
            }
            return
        }

        // Route hx command to native Helix editor
        if lowerCommand.hasPrefix("hx ") || lowerCommand == "hx" {
            handleHelixCommand(trimmedCommand)
            return
        }

        // Route rf command to native file browser
        if lowerCommand == "rf" || lowerCommand.hasPrefix("rf ") {
            handleRFCommand(trimmedCommand)
            return
        }

        // Route imgcat command to Kitty graphics protocol handler
        if lowerCommand.hasPrefix("imgcat ") || lowerCommand == "imgcat" {
            handleImgcatCommand(trimmedCommand)
            return
        }

        // Route `wasm <file>` and any bare `*.wasm` invocation to the WASM
        // runtime, including forms with a leading shell-assignment prefix
        // like `FOO=bar wasm tool.wasm` — `wasmInvocationKind` peels off
        // `NAME=value` tokens before checking, matching what
        // `prepareWasmLaunch` does on the other side.
        //
        // When the command carries pipe/redirect/sequencing operators
        // (`|`, `>`, `<`, `;`, `&`, `&&`, `||`), it goes through the shell
        // interpreter so each pipeline stage runs separately — the
        // interpreter calls `streamExternalCommand` per stage, which
        // recognises `.wasm` and routes to `streamWasmCommand` with the
        // pipeline's raw-bytes `outputSink`. Without this branch, the input
        // dispatcher would hand the whole string to `handleWasmCommand`,
        // which `splitArgv`s naively and lets `|`/`>` leak into argv.
        if Self.wasmInvocationKind(in: trimmedCommand) != .none {
            if Self.commandContainsUnquotedShellOperator(trimmedCommand) {
                executeInteractiveScript(trimmedCommand)
            } else {
                handleWasmCommand(trimmedCommand)
            }
            return
        }

        // Route bssid through ios_system (supports pipes/redirects)
        if lowerCommand == "bssid" || lowerCommand.hasPrefix("bssid ") {
            let truncatedCommand = String(trimmedCommand.prefix(30))
            onTitleChange?(truncatedCommand)
            commandQueue.async { [weak self] in
                self?.runExternalCommand(command)
            }
            return
        }

        // Route whatismyip/whatismyip4/whatismyip6 through ios_system (supports pipes/redirects)
        if lowerCommand == "whatismyip" || lowerCommand.hasPrefix("whatismyip ") ||
           lowerCommand == "whatismyip4" || lowerCommand.hasPrefix("whatismyip4 ") ||
           lowerCommand == "whatismyip6" || lowerCommand.hasPrefix("whatismyip6 ") {
            let truncatedCommand = String(trimmedCommand.prefix(30))
            onTitleChange?(truncatedCommand)
            commandQueue.async { [weak self] in
                self?.runExternalCommand(command)
            }
            return
        }

        if command == "help" {
            displayHelp()
            return
        } else if lowerCommand == "shelltest" || lowerCommand.hasPrefix("shelltest ") {
            handleShellTestCommand(trimmedCommand)
            return
        } else if command == "history" {
            displayHistory()
            return
        } else if command == "clear" {
            handleCtrlL()
            return
        } else if lowerCommand == "reset" || lowerCommand.hasPrefix("reset ") {
            handleResetCommand(trimmedCommand)
            return
        } else if command == "exit" || command == "logout" {
            if rfShellSuspended {
                rfShellSuspended = false
                resumeRF()
                return
            }
            onOutput?("logout\r\n")
            stop()
            onSessionEnd?()
            return
        } else if lowerCommand == "source" || lowerCommand.hasPrefix("source ") {
            handleSourceCommand(trimmedCommand)
            return
        } else if lowerCommand == "editrc" {
            handleEditRCCommand()
            return
        } else if lowerCommand == "editprompt" {
            handleEditPromptCommand()
            return
        } else if lowerCommand == "reloadconfig" || lowerCommand.hasPrefix("reloadconfig ") {
            handleReloadConfigCommand(trimmedCommand)
            return
        }

        // Route sh/bash invocations with proper flag and quote handling
        if lowerCommand.hasPrefix("sh ") || lowerCommand.hasPrefix("bash ") ||
           lowerCommand == "sh" || lowerCommand == "bash" {
            let words = Self.tokenizeToWords(trimmedCommand)

            // Bare sh/bash with no arguments — already in a shell
            guard words.count > 1 else {
                displayPrompt()
                return
            }

            // Parse flags and find -c or script path
            var hasDashC = false
            var dashCArgIndex: Int?
            var scriptPathIndex: Int?

            var i = 1 // skip "sh"/"bash"
            while i < words.count {
                let arg = words[i]
                if arg == "--" {
                    // End of options — next arg is script path
                    i += 1
                    if i < words.count {
                        scriptPathIndex = i
                    }
                    break
                }
                if arg.hasPrefix("-") && arg != "-" {
                    // Parse flag characters
                    let flags = arg.dropFirst()
                    if flags.contains("c") {
                        hasDashC = true
                        dashCArgIndex = i + 1
                        break
                    }
                    // Other flags (-l, -i, -x, -e, -u, -n, -v, -s) — skip
                    i += 1
                } else {
                    // First non-flag argument is script path
                    scriptPathIndex = i
                    break
                }
            }

            if hasDashC {
                // sh -c 'command string' [name [args...]]
                if let argIdx = dashCArgIndex, argIdx < words.count {
                    let commandString = words[argIdx]
                    let scriptName = argIdx + 1 < words.count ? words[argIdx + 1] : "sh"
                    let args = argIdx + 2 < words.count ? Array(words[(argIdx + 2)...]) : []
                    executeInteractiveScript(commandString, scriptName: scriptName, arguments: args)
                } else {
                    lastCommandSucceeded = false
                    onOutput?(normalizeLineEndings("sh: -c: option requires an argument\n"))
                    displayPrompt()
                }
                return
            }

            if let pathIdx = scriptPathIndex {
                let scriptPath = words[pathIdx]
                let args = pathIdx + 1 < words.count
                    ? Array(words[(pathIdx + 1)...])
                    : []
                executeScript(at: scriptPath, arguments: args)
                return
            }

            // Only flags, no -c, no script path (e.g., "sh -l") — no-op
            displayPrompt()
            return
        }

        // Route ./script.sh or /path/to/script.sh execution
        if trimmedCommand.hasPrefix("./") || trimmedCommand.hasPrefix("/") {
            let words = Self.tokenizeToWords(trimmedCommand)
            guard !words.isEmpty else { return }
            let scriptPath = words[0]
            let resolvedPath = resolveScriptPath(scriptPath)
            if FileManager.default.fileExists(atPath: resolvedPath) && isShellScript(at: resolvedPath) {
                // Check POSIX execute permission via stat (FileManager.isExecutableFile
                // can be unreliable on iOS sandbox)
                var statBuf = stat()
                let hasExecBit = stat(resolvedPath, &statBuf) == 0 && (statBuf.st_mode & S_IXUSR) != 0
                if !hasExecBit {
                    onOutput?(normalizeLineEndings("sh: \(scriptPath): Permission denied\n"))
                    displayPrompt()
                    return
                }
                let args = words.count > 1 ? Array(words[1...]) : []
                executeScript(at: scriptPath, arguments: args)
                return
            }
        }

        // Route compound commands to shell interpreter (if/for/while/until/case/function defs)
        if ShellParser.isCompoundCommand(trimmedCommand) {
            executeInteractiveScript(trimmedCommand)
            return
        }

        // Route shell builtins that aren't available in ios_system (sleep, printf, test, etc.)
        // Extract the command name (first word) and check against our builtins table
        let firstWord = trimmedCommand.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmedCommand
        if ShellBuiltins.isInterpreterOnly(firstWord) {
            executeInteractiveScript(trimmedCommand)
            return
        }

        // Update tab title to show running command (truncate to 30 chars)
        let truncatedCommand = String(command.prefix(30))
        onTitleChange?(truncatedCommand)

        // Dispatch to background queue to avoid blocking MainActor
        // ios_command_wait() blocks until command completes
        commandQueue.async { [weak self] in
            self?.runExternalCommand(command)
        }
    }

    /// Expand one leading ios_system alias before Rootshell's native-command
    /// router runs. Without this, aliases that resolve to native commands
    /// (`tssh`, `mosh`, `ssh`, etc.) are expanded only inside ios_system,
    /// where those commands are not real binaries.
    private func expandLeadingAlias(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let split = Self.splitFirstShellWordRaw(trimmed)
        else {
            return nil
        }

        let firstWord = split.word
        guard !firstWord.hasPrefix("\\") else {
            return nil
        }

        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)
        ios_switchSession(sessionPtr)

        guard let aliasValue = aliasedCommand(firstWord),
              aliasValue != firstWord
        else {
            return nil
        }

        let remainder = split.remainder.trimmingCharacters(in: .whitespaces)
        let expanded = Self.applyAliasArguments(aliasValue: aliasValue, remainder: remainder)
            .trimmingCharacters(in: .whitespaces)

        guard let expandedFirstWord = Self.splitFirstShellWordRaw(expanded)?.word else {
            return nil
        }

        let routedName = (expandedFirstWord as NSString).lastPathComponent.lowercased()
        guard Self.aliasPreExpansionCommandNames.contains(routedName) else {
            return nil
        }

        return expanded
    }

    private func handleTab() {
        // Check if we're completing an SSH command
        let buffer = lineEditor.buffer
        let lowerBuffer = buffer.lowercased()

        if lowerBuffer.hasPrefix("ssh ") {
            generalCompletionState = .idle
            handleSSHTabCompletion()
            return
        }

        // Check if we're completing a mosh/roam command
        if lowerBuffer.hasPrefix("mosh ") || lowerBuffer.hasPrefix("roam ") {
            generalCompletionState = .idle
            handleMoshTabCompletion()
            return
        }

        // Check if we're completing an SCP command
        if lowerBuffer.hasPrefix("scp ") {
            generalCompletionState = .idle
            handleSCPTabCompletion()
            return
        }

        // Check if we're completing an SFTP command
        if lowerBuffer.hasPrefix("sftp ") {
            generalCompletionState = .idle
            handleSFTPTabCompletion()
            return
        }

        // Check if we're completing a tssh/trzsz command
        if lowerBuffer.hasPrefix("tssh ") || lowerBuffer.hasPrefix("trzsz ") {
            generalCompletionState = .idle
            handleTrzszTabCompletion()
            return
        }

        // Check if we're completing an ssh-copy-id command
        if lowerBuffer.hasPrefix("ssh-copy-id ") {
            generalCompletionState = .idle
            handleSSHCopyIDTabCompletion()
            return
        }

        // General file/command completion state machine
        switch generalCompletionState {
        case .idle:
            handleFirstTab()

        case .waitingForSecondTab(let matches, let displayNames, let range):
            displayCompletionMatches(displayNames)
            generalCompletionState = .cycling(
                originalBuffer: lineEditor.buffer,
                allMatches: matches,
                range: range,
                currentIndex: -1
            )

        case .cycling(let origBuffer, let matches, let range, var idx):
            idx = (idx + 1) % matches.count
            lineEditor.setBuffer(origBuffer)
            lineEditor.replaceText(in: range, with: matches[idx])
            clearGhostText()
            redrawLine()
            generalCompletionState = .cycling(
                originalBuffer: origBuffer,
                allMatches: matches,
                range: range,
                currentIndex: idx
            )
        }
    }

    /// Handle the first tab press — query CompletionProvider and apply result
    private func handleFirstTab() {
        let result = completionProvider.complete(
            line: lineEditor.buffer,
            cursorPosition: lineEditor.cursorPosition,
            workingDirectory: sessionCurrentDirectory
        )

        switch result {
        case .singleMatch(let text, let range):
            lineEditor.replaceText(in: range, with: text)
            clearGhostText()
            redrawLine()
            // Stay idle — single match fully applied

        case .extendedToCommonPrefix(let text, let range, let allMatches, let displayNames):
            lineEditor.replaceText(in: range, with: text)
            clearGhostText()
            redrawLine()
            onBell?()
            // Range must reflect the extended text, not the original typed prefix.
            // replaceText places the cursor at the end of the insertion.
            let updatedRange = range.lowerBound..<lineEditor.cursorPosition
            generalCompletionState = .waitingForSecondTab(
                allMatches: allMatches,
                displayNames: displayNames,
                range: updatedRange
            )

        case .showAllMatches(let allMatches, let displayNames, let range):
            displayCompletionMatches(displayNames)
            onBell?()
            generalCompletionState = .cycling(
                originalBuffer: lineEditor.buffer,
                allMatches: allMatches,
                range: range,
                currentIndex: -1
            )

        case .noMatch:
            onBell?()
        }
    }

    /// Display completion matches in columns below the current line, then redraw prompt
    private func displayCompletionMatches(_ names: [String]) {
        guard !names.isEmpty else { return }

        let termWidth = max(Int(pty.windowSize.cols), 20)
        let maxNameWidth = names.map(\.count).max() ?? 1
        let colWidth = maxNameWidth + 2  // 2 chars padding between columns
        let numCols = max(termWidth / colWidth, 1)
        let numRows = (names.count + numCols - 1) / numCols  // ceil division

        var output = "\r\n"

        // Column-major order (like ls): items fill down columns first
        for row in 0..<numRows {
            for col in 0..<numCols {
                let index = col * numRows + row
                guard index < names.count else { break }
                let name = names[index]
                if col < numCols - 1 && (col + 1) * numRows + row < names.count {
                    // Pad to column width
                    output += name + String(repeating: " ", count: max(colWidth - name.count, 1))
                } else {
                    // Last column or last item in row — no padding
                    output += name
                }
            }
            output += "\r\n"
        }

        onOutput?(output)
        displayPromptAndBuffer()
    }

    /// Redraw the prompt and current buffer after printing match list
    private func displayPromptAndBuffer() {
        let buffer = lineEditor.buffer
        let terminalWidth = Int(pty.windowSize.cols)

        let prompt = getCurrentPromptResult()

        // Right prompt ANSI sequence (cursor-positioned on info bar)
        var rightPromptSeq = ""
        if prompt.rightPromptWidth > 0, !prompt.rightPromptText.isEmpty {
            let rightCol = terminalWidth - prompt.rightPromptWidth + 1
            if rightCol > 0 {
                rightPromptSeq += "\u{1b}[1A"
                rightPromptSeq += "\u{1b}[\(rightCol)G"
                rightPromptSeq += prompt.rightPromptText
                rightPromptSeq += PromptStyle.ansiReset
                rightPromptSeq += "\u{1b}[1B"
                rightPromptSeq += "\r"
                rightPromptSeq += "\u{1b}[\(prompt.secondLinePrefix)C"
            }
        }

        if prompt.secondLinePrefix > 0, useStarshipPrompt || PromptConfigManager.shared.hasConfigFile() {
            var out = prompt.text + rightPromptSeq

            if !buffer.isEmpty {
                let prefixWidth = prompt.secondLinePrefix
                let totalRows = CursorTracker.calculateTotalRows(
                    promptSecondLinePrefix: prefixWidth,
                    bufferLength: lineEditor.displayWidth,
                    terminalWidth: terminalWidth
                )
                let (targetRow, targetCol) = CursorTracker.calculateCursorPosition(
                    promptSecondLinePrefix: prefixWidth,
                    bufferCursorPosition: lineEditor.cursorColumn,
                    terminalWidth: terminalWidth
                )
                let cursorMove = CursorTracker.cursorPositionSequence(
                    totalRows: totalRows,
                    targetRow: targetRow,
                    targetCol: targetCol
                )
                out += buffer + cursorMove
            }
            onOutput?(out)
        } else {
            var out = prompt.text
            if !buffer.isEmpty {
                let cursorOffset = lineEditor.widthAfterCursor
                let cursorMove = cursorOffset > 0 ? "\u{1b}[\(cursorOffset)D" : ""
                out += buffer + cursorMove
            }
            onOutput?(out)
        }
    }

    private func handleBackspace() {
        generalCompletionState = .idle
        if lineEditor.deleteBackward() {
            // Update ghost text after deletion
            updateGhostText()
            redrawLine()
        } else {
            // Nothing to delete, beep
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
        }
    }

    private func handleDelete() {
        generalCompletionState = .idle
        if lineEditor.deleteForward() {
            // Update ghost text after deletion
            updateGhostText()
            redrawLine()
        } else {
            // Nothing to delete, beep
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
        }
    }

    private func handleWordLeft() {
        generalCompletionState = .idle
        if lineEditor.moveCursorToPreviousWord() {
            updateGhostText()
            redrawLine()
        }
    }

    private func handleWordRight() {
        generalCompletionState = .idle
        if lineEditor.moveCursorToNextWord() {
            updateGhostText()
            redrawLine()
        }
    }

    private func handleCtrlA() {
        generalCompletionState = .idle
        if lineEditor.moveCursorToStart() {
            updateGhostText()
            redrawLine()
        }
    }

    private func handleCtrlE() {
        generalCompletionState = .idle
        if lineEditor.moveCursorToEnd() {
            updateGhostText()
            redrawLine()
        }
    }

    private func handleCtrlK() {
        generalCompletionState = .idle
        let killedText = lineEditor.textAfterCursor
        if lineEditor.deleteToEnd() {
            lineEditorYankBuffer = killedText
            updateGhostText()
            redrawLine()
        }
    }

    private func handleCtrlU() {
        generalCompletionState = .idle
        let killedText = lineEditor.textBeforeCursor
        if lineEditor.deleteToStart() {
            lineEditorYankBuffer = killedText
            updateGhostText()
            redrawLine()
        }
    }

    private func handleCtrlY() {
        generalCompletionState = .idle
        guard !lineEditorYankBuffer.isEmpty else { return }
        if lineEditor.insertText(lineEditorYankBuffer) {
            updateGhostText()
            redrawLine()
        }
    }

    private func handleCtrlW() {
        generalCompletionState = .idle
        if lineEditor.deleteWordBackward() {
            updateGhostText()
            redrawLine()
        }
    }

    private func handleCtrlL() {
        generalCompletionState = .idle
        // Clear screen and redraw prompt with current buffer
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Clear screen and home cursor
            self.onOutput?("\u{1b}[2J\u{1b}[H")

            // Update tab title
            let currentPath = sessionCurrentDirectory
            self.onWorkingDirectoryChange?(currentPath)
            let formattedPath = self.formatPathForTitle(currentPath)
            self.onTitleChange?(formattedPath)

            let prompt = self.getCurrentPromptResult()
            if prompt.addsLeadingSeparator {
                self.onOutput?("\r\n")
            }

            let isMultiLine = prompt.secondLinePrefix > 0 && (self.useStarshipPrompt || PromptConfigManager.shared.hasConfigFile())

            if prompt.rightPromptWidth > 0 {
                self.onOutput?(self.renderPromptWithRightAlign(prompt))
            } else {
                self.onOutput?(prompt.text)
            }

            // Render existing buffer content with cursor positioning
            if !self.lineEditor.buffer.isEmpty {
                let buffer = self.lineEditor.buffer

                if isMultiLine {
                    let terminalWidth = Int(self.pty.windowSize.cols)
                    let prefixWidth = prompt.secondLinePrefix

                    let totalRows = CursorTracker.calculateTotalRows(
                        promptSecondLinePrefix: prefixWidth,
                        bufferLength: self.lineEditor.displayWidth,
                        terminalWidth: terminalWidth
                    )
                    let (targetRow, targetCol) = CursorTracker.calculateCursorPosition(
                        promptSecondLinePrefix: prefixWidth,
                        bufferCursorPosition: self.lineEditor.cursorColumn,
                        terminalWidth: terminalWidth
                    )
                    let cursorMove = CursorTracker.cursorPositionSequence(
                        totalRows: totalRows,
                        targetRow: targetRow,
                        targetCol: targetCol
                    )
                    self.onOutput?(buffer + cursorMove)
                } else {
                    let cursorOffset = self.lineEditor.widthAfterCursor
                    let cursorMove = cursorOffset > 0 ? "\u{1b}[\(cursorOffset)D" : ""
                    self.onOutput?(buffer + cursorMove)
                }
            }
        }
    }

    func handleResetCommand(_ command: String) {
        generalCompletionState = .idle

        let args = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let arg = args.dropFirst().first {
            if arg == "-h" || arg == "--help" {
                lastCommandSucceeded = true
                scriptCommandExitCode = 0
                displayResetHelp()
            } else {
                lastCommandSucceeded = false
                scriptCommandExitCode = 1
                onOutput?(normalizeLineEndings("usage: reset\n"))
                displayPrompt()
            }
            return
        }

        onTerminalReset?()
        lastCommandSucceeded = true
        scriptCommandExitCode = 0
        displayPrompt()
    }

    private func handleCtrlD() {
        // EOF - if line is empty, exit shell
        if lineEditor.buffer.isEmpty {
            Task { @MainActor [weak self] in
                self?.onOutput?("exit\r\n")
                self?.stop()
                self?.onSessionEnd?()
            }
        }
    }

    private func handleArrowUp() {
        generalCompletionState = .idle
        // Only start navigation if not already navigating
        if !historyManager.isNavigating {
            historyManager.startNavigation(currentBuffer: lineEditor.buffer)
        }

        if let command = historyManager.navigatePrevious() {
            lineEditor.setBuffer(command)
            // Update ghost text for the new buffer content
            updateGhostText()
            redrawLine()
        }
    }

    private func handleArrowDown() {
        generalCompletionState = .idle
        if let command = historyManager.navigateNext() {
            lineEditor.setBuffer(command)
            // Update ghost text for the new buffer content
            updateGhostText()
            redrawLine()
        }
    }

    private func handleArrowLeft() {
        generalCompletionState = .idle
        if lineEditor.moveCursorLeft() {
            // Update ghost text when cursor moves (only show when at end)
            updateGhostText()
            redrawLine()
        }
    }

    private func handleArrowRight() {
        generalCompletionState = .idle
        if lineEditor.moveCursorRight() {
            // Update ghost text when cursor moves (only show when at end)
            updateGhostText()
            redrawLine()
        }
    }

    private func insertCharacter(_ char: Character) {
        // Stop history navigation when user starts typing
        historyManager.stopNavigation()
        generalCompletionState = .idle

        // Reset suggestion caches when user types
        sshCompletion.reset()
        scpCompletion.reset()
        sftpCompletion.reset()
        moshCompletion.reset()
        trzszCompletion.reset()
        sshCopyIDCompletion.reset()

        lineEditor.insertText(String(char))

        // Update ghost text for SSH command completion
        updateGhostText()

        redrawLine()
    }

    /// Redraw the current line (clears and reprints with cursor position)
    func redrawLine() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let buffer = self.lineEditor.buffer
            let terminalWidth = Int(self.pty.windowSize.cols)
            let ghostText = self.currentGhostText

            // ANSI codes for ghost text styling (dim gray)
            let ghostStart = "\u{1b}[2;90m"  // Dim + Gray foreground
            let ghostEnd = "\u{1b}[0m"       // Reset all attributes

            // In multi-line input mode, use simple "> " continuation prompt
            if self.multiLineInputBuffer != nil {
                let clearLine = "\r\u{1b}[K"
                let totalAfterCursor = self.lineEditor.widthAfterCursor
                let cursorMove = totalAfterCursor > 0 ? "\u{1b}[\(totalAfterCursor)D" : ""
                self.onOutput?(clearLine + "> " + buffer + cursorMove)
                return
            }

            let prompt = self.getCurrentPromptResult()
            let isMultiLine = prompt.secondLinePrefix > 0 && (self.useStarshipPrompt || PromptConfigManager.shared.hasConfigFile())

            if isMultiLine {
                let prefixWidth = prompt.secondLinePrefix

                // Calculate total rows that input line(s) will occupy (include ghost text width).
                // Measured in display cells, not characters — CJK/emoji occupy 2 cells.
                let totalContentLength = self.lineEditor.displayWidth + DisplayWidth.width(of: ghostText)
                let totalRows = CursorTracker.calculateTotalRows(
                    promptSecondLinePrefix: prefixWidth,
                    bufferLength: totalContentLength,
                    terminalWidth: terminalWidth
                )

                // Calculate cursor target position in row/col (cursor is at buffer position, not ghost text)
                let (targetRow, targetCol) = CursorTracker.calculateCursorPosition(
                    promptSecondLinePrefix: prefixWidth,
                    bufferCursorPosition: self.lineEditor.cursorColumn,
                    terminalWidth: terminalWidth
                )

                // Generate cursor positioning sequence
                let cursorMove = CursorTracker.cursorPositionSequence(
                    totalRows: totalRows,
                    targetRow: targetRow,
                    targetCol: targetCol
                )

                // Extract just the input line prefix (chevron + space) from prompt.text.
                // This is everything after the last \r\n — avoids redrawing the info bar.
                let inputPrefix: String
                if let lastCRLF = prompt.text.range(of: "\r\n", options: .backwards) {
                    inputPrefix = String(prompt.text[lastCRLF.upperBound...])
                } else {
                    inputPrefix = prompt.text
                }

                // Move up to start of input area (not info bar), clear from there
                let cursorRow = targetRow
                var moveToInputStart = ""
                if cursorRow > 0 {
                    moveToInputStart = "\u{1b}[\(cursorRow)A"
                }
                let clearToEnd = "\r\u{1b}[J"  // CR + Erase from cursor to end of display

                // Build output with ghost text after buffer
                let ghostTextDisplay = ghostText.isEmpty ? "" : ghostStart + ghostText + ghostEnd
                self.onOutput?(moveToInputStart + clearToEnd + inputPrefix + buffer + ghostTextDisplay + cursorMove)
            } else {
                // Simple single-line prompt - original behavior
                let clearLine = "\r\u{1b}[K"
                // Ghost text width affects cursor offset calculation (display cells, not chars)
                let ghostTextDisplay = ghostText.isEmpty ? "" : ghostStart + ghostText + ghostEnd
                let totalAfterCursor = self.lineEditor.widthAfterCursor + DisplayWidth.width(of: ghostText)
                let cursorMove = totalAfterCursor > 0 ? "\u{1b}[\(totalAfterCursor)D" : ""
                self.onOutput?(clearLine + prompt.text + buffer + ghostTextDisplay + cursorMove)
            }
        }
    }

    // MARK: - Shell Tokenization Helpers

    /// Strip PUA quote markers from a tokenized word to get plain text.
    private static func stripPUAMarkers(_ text: String) -> String {
        text.filter { c in
            c != ShellTokenizer.singleQuoteStart && c != ShellTokenizer.singleQuoteEnd &&
            c != ShellTokenizer.doubleQuoteStart && c != ShellTokenizer.doubleQuoteEnd
        }
    }

    /// Split a command string into its first shell word and the remaining raw
    /// text. Quotes and backslash escapes are honored only far enough to avoid
    /// splitting inside quoted arguments; returned text keeps the user's raw
    /// quoting so native parsers and ios_system can process it normally.
    private static func splitFirstShellWordRaw(_ command: String) -> (word: String, remainder: String)? {
        var index = command.startIndex
        while index < command.endIndex, command[index].isWhitespace {
            index = command.index(after: index)
        }
        guard index < command.endIndex else { return nil }

        let wordStart = index
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        while index < command.endIndex {
            let character = command[index]

            if escaped {
                escaped = false
                index = command.index(after: index)
                continue
            }

            if character == "\\" && !inSingleQuote {
                escaped = true
                index = command.index(after: index)
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                index = command.index(after: index)
                continue
            }

            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                index = command.index(after: index)
                continue
            }

            if character.isWhitespace && !inSingleQuote && !inDoubleQuote {
                let word = String(command[wordStart..<index])
                let remainder = String(command[index...])
                return (word, remainder)
            }

            index = command.index(after: index)
        }

        return (String(command[wordStart..<command.endIndex]), "")
    }

    /// Apply ios_system's alias argument markers to the remaining command text:
    /// no marker appends all arguments, `!*` inserts arguments before the tail,
    /// and `!^` inserts only the first argument before the tail.
    private static func applyAliasArguments(aliasValue: String, remainder: String) -> String {
        if aliasValue.contains("!*") {
            return aliasValue.replacingOccurrences(of: "!*", with: remainder)
                .trimmingCharacters(in: .whitespaces)
        } else if aliasValue.contains("!^") {
            let firstAndRest = splitFirstShellWordRaw(remainder)
            let firstArg = firstAndRest?.word ?? ""
            let restArgs = firstAndRest?.remainder.trimmingCharacters(in: .whitespaces) ?? ""
            var expanded = aliasValue.replacingOccurrences(of: "!^", with: firstArg)
            if !restArgs.isEmpty {
                expanded += " " + restArgs
            }
            return expanded.trimmingCharacters(in: .whitespaces)
        }

        guard !remainder.isEmpty else {
            return aliasValue
        }
        return aliasValue + " " + remainder
    }

    /// Detect POSIX command substitution (`$(...)`, backticks) or parameter
    /// expansion (`$VAR`, `${VAR}`, `$@`, `$?`, etc.) that ios_system won't
    /// expand. Honours single-quote, double-quote, and backslash context so
    /// that `echo '$(date)'`, `echo '$VAR'`, and `echo \$VAR` are treated as
    /// literal.
    static func commandHasShellExpansion(_ command: String) -> Bool {
        let scalars = Array(command.unicodeScalars)
        var i = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\" && !inSingleQuote {
                // Skip backslash + next scalar
                i += (i + 1 < scalars.count) ? 2 : 1
                continue
            }
            if c == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                i += 1
                continue
            }
            if c == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                i += 1
                continue
            }
            if inSingleQuote {
                i += 1
                continue
            }
            if c == "`" { return true }
            if c == "$", i + 1 < scalars.count {
                let next = scalars[i + 1]
                // $(…) command/arithmetic substitution.
                if next == "(" { return true }
                // ${…} parameter expansion.
                if next == "{" { return true }
                // $name parameter expansion (start = letter or underscore).
                let v = next.value
                if next == "_"
                    || (v >= 0x41 && v <= 0x5A) // A–Z
                    || (v >= 0x61 && v <= 0x7A) // a–z
                {
                    return true
                }
                // Positional parameters ($0–$9) and special parameters
                // ($@, $*, $#, $?, $$, $!, $-).
                if (v >= 0x30 && v <= 0x39)
                    || next == "@" || next == "*" || next == "#"
                    || next == "?" || next == "$" || next == "!" || next == "-"
                {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    /// Pre-expand a command that contains `$(...)`, `$((...))`, or backticks.
    /// Runs on `commandQueue`. Caller sets `sessionMode = .scriptRunning` before
    /// dispatching so the line editor stops accepting input during expansion.
    ///
    /// Pre-routing is deliberately narrow: it only kicks in when the expanded
    /// argv[0] names a native Swift handler (ssh, mosh, ping, git, …) and every
    /// argv entry is free of shell metacharacters. All other commands — shell
    /// functions defined in the session, interpreter builtins, ios_system
    /// externals, compound constructs, or anything producing argv entries that
    /// would require POSIX `'\''` quoting (which several native parsers don't
    /// understand) — run through the full interpreter via `runScript`, which
    /// handles shell-function dispatch and routes externals through ios_system.
    nonisolated func preExpandAndRoute(_ command: String) {
        guard !hasStopped else { return }
        let tokenizer = ShellTokenizer(source: command)
        let parser = ShellParser(tokenizer: tokenizer)

        let ast: ShellCommand
        do {
            ast = try parser.parse()
        } catch {
            runScript(command, name: "sh", arguments: [], useSharedEnvironment: true)
            return
        }

        guard case .simple(let simple) = ast else {
            runScript(command, name: "sh", arguments: [], useSharedEnvironment: true)
            return
        }

        let interpreter = makeRoutingExpansionInterpreter()

        // Publish the throwaway interpreter so Ctrl-C and prompt suppression
        // see it while expansion is running. Swift's unstructured `Task { @MainActor }`
        // hops aren't strictly ordered relative to each other, so any later
        // state transition that CLEARS `activeShellInterpreter` must chain on
        // this task's value via `await` — otherwise scheduler re-ordering
        // could leave a stale non-nil after native routing has taken over
        // (making later SSH/git/ping sessions wrongly suppress the prompt
        // and misroute cancellation).
        let publishedThrowaway: Task<Void, Never> = Task { @MainActor [weak self] in
            self?.activeShellInterpreter = interpreter
        }

        let argv: [String]?
        do {
            argv = try interpreter.expandSimpleCommandArgv(simple)
        } catch ShellError.cancelled {
            Task { @MainActor [weak self] in
                await publishedThrowaway.value
                self?.recoverFromScriptExecution()
            }
            return
        } catch {
            // Expansion threw partway through. Some substitutions may have
            // already run (with side effects — `touch`, file writes, env
            // mutations). Re-dispatching the original source via runScript
            // would execute each of them a second time, so surface the error
            // and recover instead.
            let errorDescription = error.localizedDescription
            Task { @MainActor [weak self] in
                await publishedThrowaway.value
                guard let self else { return }
                self.activeShellInterpreter = nil
                self.onOutput?(self.normalizeLineEndings("sh: \(errorDescription)\n"))
                self.lastCommandSucceeded = false
                self.recoverFromScriptExecution()
            }
            return
        }

        guard let argv, let commandName = argv.first else {
            // `expandSimpleCommandArgv` returns nil BEFORE running any word
            // expansion when the simple command has pre-command assignments,
            // redirections, or a here-doc (see `ShellInterpreter.swift`).
            // No substitutions ran, so re-dispatching the original source
            // via runScript is safe — it'll expand once.
            fallThroughToRunScript(command, publishedThrowaway: publishedThrowaway)
            return
        }

        // `bash -c <script>` / `sh -c <script>` — keep the already-expanded
        // script body inside our Swift interpreter. Without this, the rebuild
        // path below produces `bash -c '<body>'` and hands it to ios_system,
        // whose ios_shell_parser then re-scans the body for `$(…)`/backticks.
        // Its single-quote tracking can't handle bash's `'\''` POSIX
        // quote-escape idiom, so it ends up running substitutions on text
        // that's inside bash comments / single-quoted literals — corrupting
        // the heap on long inputs (Homebrew `install.sh` repro).
        let normalizedName = (commandName as NSString).lastPathComponent.lowercased()
        if (normalizedName == "bash" || normalizedName == "sh"),
           let scriptBody = Self.dashCScriptBody(argv: argv) {
            Task { @MainActor [weak self] in
                await publishedThrowaway.value
                guard let self else { return }
                self.activeShellInterpreter = nil
                self.sessionMode = .localShell
                if self.isRunning { self.scriptCancellationToken.reset() }
                self.executeInteractiveScript(scriptBody, scriptName: normalizedName)
            }
            return
        }

        // Shell functions are only visible through the interpreter. If the
        // expanded command name resolves to one, we MUST NOT route to ios_system
        // via a rebuilt string (it would become "command not found").
        let resolvesToFunction = sharedShellEnvironment.getFunction(commandName) != nil

        // Non-native commands (shell functions, ios_system externals, builtins)
        // are safely handled by the full interpreter, which dispatches builtins
        // on argv directly and sends externals to ios_system via the POSIX
        // `shellEscape` form that ios_system's own tokeniser understands.
        let isNativeRoutedName = Self.nativeRoutedCommandNames.contains(commandName.lowercased())

        guard !resolvesToFunction, isNativeRoutedName else {
            // We already expanded argv above — handing the *original* source
            // (with `$(…)` still present) to runScript would run every
            // substitution a second time. Instead, POSIX-shellEscape each
            // already-expanded field and feed that substitution-free string
            // to runScript, which re-parses it and dispatches to the correct
            // builtin / shell function / external as usual. No substitutions
            // remain in the string, so no re-execution.
            let rebuilt = argv.map { Self.posixShellEscapeForIOSSystem($0) }
                              .joined(separator: " ")
            fallThroughToRunScript(rebuilt, publishedThrowaway: publishedThrowaway)
            return
        }

        // git needs argv-based dispatch end-to-end: the top-level git router
        // uses naive space splitting in `gitCommandNeedsInterception` and
        // `prepareGitForIOSSystem`, which mis-tokenises rebuilt strings that
        // include quoted spaces (e.g., `git -C 'repo with space' commit`
        // misclassifies "with" as the subcommand). Decide intercept vs
        // ios_system on argv and dispatch directly to the final handler.
        if commandName.lowercased() == "git" {
            dispatchExpandedGitCommand(argv: argv, publishedThrowaway: publishedThrowaway)
            return
        }

        // Rebuild a command string the native tokenisers (SSHCommandParser,
        // PingCommandParser, etc.) will round-trip. They understand naive
        // whole-token `'...'` and `"..."` quoting but NOT POSIX `'\''` escapes
        // or backslash escapes, so we can't use `shellEscape` here.
        guard let rebuilt = Self.rebuildCommandForNativeTokeniser(argv: argv) else {
            // Argument contains both `'` and `"` — no form the naive tokenisers
            // can represent. Surface a clear error instead of silently corrupting.
            Task { @MainActor [weak self] in
                // Await the publish so the subsequent clear can't be reordered
                // ahead of it (see `publishedThrowaway` comment above).
                await publishedThrowaway.value
                guard let self else { return }
                self.activeShellInterpreter = nil
                self.onOutput?(self.normalizeLineEndings(
                    "sh: \(commandName): expanded argument contains unsupported characters\n"
                ))
                self.lastCommandSucceeded = false
                self.recoverFromScriptExecution()
            }
            return
        }

        Task { @MainActor [weak self] in
            // Await the publish before clearing so a re-ordered "publish
            // throwaway" task can't resurrect `activeShellInterpreter` after
            // a native handler (ssh/ping/…) has already taken over.
            await publishedThrowaway.value
            guard let self else { return }
            self.activeShellInterpreter = nil
            self.sessionMode = .localShell
            if self.isRunning { self.scriptCancellationToken.reset() }
            self.handleCommandSubmission(rebuilt, alreadyExpanded: true)
        }
    }

    /// Hand an un-expanded command to `runScript` while keeping ordering
    /// bulletproof relative to the throwaway-interpreter publish.
    ///
    /// Without chaining, the runScript path has three unordered publishes on
    /// MainActor: the throwaway publish here, runScript's own interpreter
    /// publish, and `recoverFromScriptExecution`'s clear. Any of them could
    /// be re-ordered by Swift's unstructured-task scheduler, including the
    /// throwaway publish landing *after* recover — resurrecting
    /// `activeShellInterpreter` long after the script finished, which would
    /// wrongly suppress the prompt and misroute subsequent Ctrl-C.
    ///
    /// By awaiting `publishedThrowaway.value` on the MainActor before
    /// re-dispatching to `commandQueue`, we guarantee the throwaway publish
    /// has already landed before runScript starts. runScript's own publishes
    /// happen strictly later (created inside `runScript` on the command
    /// queue), so their ordering with each other is temporal, not scheduler-
    /// dependent.
    nonisolated func fallThroughToRunScript(_ command: String, publishedThrowaway: Task<Void, Never>) {
        Task { @MainActor [weak self] in
            await publishedThrowaway.value
            guard let self else { return }
            self.commandQueue.async { [weak self] in
                self?.runScript(command, name: "sh", arguments: [], useSharedEnvironment: true)
            }
        }
    }

    /// Dispatch an expanded git command directly to its final handler, bypassing
    /// the top-level naive-split router. Mirrors the top-level decision tree in
    /// `handleCommandSubmission` — native editor path for intercepted cases,
    /// else ios_system via `runExternalCommand` with color/paging prep applied —
    /// but keeps argv-based classification so substitution-produced whitespace
    /// and quotes in arguments don't corrupt the subcommand detection.
    nonisolated func dispatchExpandedGitCommand(argv: [String], publishedThrowaway: Task<Void, Never>) {
        let needsIntercept = Self.gitArgvNeedsInterception(argv)

        if needsIntercept {
            // Pass argv straight to `GitCommandParser.parseArgs` via
            // `handleGitCommand(argv:)` — no string rebuild, so even argv
            // entries carrying both `'` and `"` keep the native git path
            // (commit editor, auth-flag credential prompts, etc.).
            Task { @MainActor [weak self] in
                // Await the publish so a re-ordered "publish throwaway" task
                // can't resurrect `activeShellInterpreter` after git has taken
                // over (would wrongly suppress prompts / misroute Ctrl-C).
                await publishedThrowaway.value
                guard let self else { return }
                self.activeShellInterpreter = nil
                self.sessionMode = .localShell
                if self.isRunning { self.scriptCancellationToken.reset() }
                self.handleGitCommand(argv: argv)
            }
            return
        }

        // Non-intercepted git: apply `--color=always` injection and `bat`
        // auto-paging directly on argv, POSIX-escape each field for ios_system,
        // and dispatch via `runExternalCommand` — same behaviour as the
        // top-level git branch, minus the naive-split hazard.
        let prepared = Self.prepareGitArgvForIOSSystem(argv)
        Task { @MainActor [weak self] in
            await publishedThrowaway.value
            guard let self else { return }
            self.activeShellInterpreter = nil
            self.sessionMode = .localShell
            if self.isRunning { self.scriptCancellationToken.reset() }
            let truncated = String(prepared.prefix(30))
            self.onTitleChange?(truncated)
            self.commandQueue.async { [weak self] in
                self?.runExternalCommand(prepared)
            }
        }
    }

    /// Rebuild an expanded argv into a command string the native-handler
    /// tokenisers can re-tokenise. The session's native parsers fall into two
    /// dialects:
    ///   - Naive (SSHCommandParser, PingCommandParser, …): whole-token quote
    ///     pairs, no escape sequences anywhere.
    ///   - Escaping (GitCommandParser, CrocCommandParser): `\` is an escape
    ///     *outside* single quotes, including inside `"..."`.
    ///
    /// Single-quoted content is a raw literal in both dialects, so we prefer
    /// that form. Double quotes are only safe when the entry has no `\` (so
    /// the escaping dialects don't consume one). An entry that requires a form
    /// neither dialect can round-trip produces nil — the caller surfaces an
    /// error rather than silently corrupting the argument.
    ///
    /// Rules per entry:
    ///   - Empty → `""`.
    ///   - Metacharacter-free → appended as-is.
    ///   - Contains no `'` → `'...'` (preserves `\`, `"`, spaces, etc.).
    ///   - Contains no `"` AND no `\` → `"..."`.
    ///   - Otherwise → nil.
    nonisolated static func rebuildCommandForNativeTokeniser(argv: [String]) -> String? {
        var parts: [String] = []
        parts.reserveCapacity(argv.count)
        for entry in argv {
            if entry.isEmpty {
                parts.append("\"\"")
                continue
            }
            if argvEntryIsSimpleForNativeRoute(entry) {
                parts.append(entry)
                continue
            }
            if !entry.contains("'") {
                parts.append("'\(entry)'")
                continue
            }
            if !entry.contains("\"") && !entry.contains("\\") {
                parts.append("\"\(entry)\"")
                continue
            }
            return nil
        }
        return parts.joined(separator: " ")
    }

    /// Commands that route to *native Swift* handlers at the top level (and
    /// therefore need a native-tokeniser-friendly rebuild after expansion).
    /// Must stay in sync with the prefix checks in `handleCommandSubmission`.
    ///
    /// Deliberately excludes commands whose top-level path delegates straight
    /// to ios_system via `runExternalCommand` (e.g., `bssid`, `whatismyip*`).
    /// Those handle POSIX `'\''` and other shell escapes natively, so the
    /// stricter naive-tokeniser rebuild would reject otherwise-valid expanded
    /// arguments — e.g., `whatismyip "$(printf "1'2\"3")"` would falsely
    /// surface an "unsupported characters" error even though ios_system can
    /// tokenise the shellEscape form produced by the runScript fallback.
    nonisolated static let nativeRoutedCommandNames: Set<String> = [
        "ssh", "scp", "sftp", "ssh-copy-id",
        "mosh", "roam",
        "tssh", "trzsz",
        "ping", "ping6",
        "mtr", "mtr6",
        "traceroute", "traceroute6",
        "git",
        "hx",
        "rf",
        "imgcat",
        "croc"
    ]

    /// Commands whose top-level Rootshell router provides behavior users
    /// expect aliases to inherit. Most stay fully native; `git` and report-mode
    /// `mtr` may hand selected work back to ios_system after applying the same
    /// routing decisions as direct commands. Leading aliases are pre-expanded
    /// only for this set so self-referential ios_system aliases (`ls='ls --color'`)
    /// still expand exactly once inside ios_system.
    private static let aliasPreExpansionCommandNames: Set<String> = [
        "clear", "exit", "logout",
        "ssh", "scp", "sftp", "ssh-copy-id",
        "mosh", "roam",
        "tssh", "trzsz",
        "ping", "ping6",
        "mtr", "mtr6",
        "traceroute", "traceroute6",
        "git",
        "hx",
        "rf",
        "imgcat",
        "croc"
    ]

    /// If `argv` is a `bash`/`sh -c <body> [name [args…]]` invocation, return
    /// the script body. Skips POSIX flag bundles (`-eu`, `-l`, etc.) up to the
    /// `-c`. Mirrors the flag handling at `handleCommandSubmission` line 459.
    nonisolated static func dashCScriptBody(argv: [String]) -> String? {
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" { return nil }
            if arg.hasPrefix("-"), arg != "-" {
                if arg.dropFirst().contains("c") {
                    let bodyIdx = i + 1
                    return bodyIdx < argv.count ? argv[bodyIdx] : nil
                }
                i += 1
                continue
            }
            return nil
        }
        return nil
    }

    /// Subcommands that route through `bat` for auto-paging when the output
    /// would otherwise go to the terminal. Must stay in sync with
    /// `LocalShellSession+Git.pagedSubcommands`.
    nonisolated static let gitPagedSubcommands: Set<String> = ["diff", "log", "blame", "reflog"]

    /// argv-based twin of `LocalShellSession+Git.prepareGitForIOSSystem`.
    /// Injects `--color=always` (unless the user already specified a colour
    /// flag), pipes paged subcommands through `bat`, and POSIX-escapes each
    /// field for ios_system's own tokeniser. Called from `preExpandAndRoute`
    /// where we already have argv; avoids the naive space-split that corrupts
    /// rebuilt strings containing quoted whitespace.
    nonisolated static func prepareGitArgvForIOSSystem(_ argv: [String]) -> String {
        guard argv.count >= 2 else {
            return argv.map { posixShellEscapeForIOSSystem($0) }.joined(separator: " ")
        }

        // `preExpandAndRoute` only delivers simple commands here (pipelines /
        // redirections fall back to `runScript` before reaching this point),
        // so operators inside argv entries are already quoted data, not shell
        // syntax. The helper therefore always sees a clean, pipe-free argv.
        let hasPipeOrRedirect = false

        let hasColorFlag = argv.contains { token in
            token == "--color" || token.hasPrefix("--color=") || token == "--no-color"
        }
        let hasProgressControl = argv.contains { token in
            token == "--progress" || token == "--no-progress" || token == "-q" || token == "--quiet"
        }

        var subcommand: String?
        var subcommandIndex: Int?
        var idx = 1
        while idx < argv.count {
            let token = argv[idx]
            if token == "-C" || token == "--git-dir" {
                idx += 2
                continue
            }
            if token == "--no-pager" || token.hasPrefix("--color") || token == "--no-color" {
                idx += 1
                continue
            }
            if token.hasPrefix("--") {
                idx += 1
                continue
            }
            if token.hasPrefix("-") && token.count > 1 {
                idx += 1
                continue
            }
            subcommand = token
            subcommandIndex = idx
            break
        }

        var workingArgv = argv
        if !hasPipeOrRedirect,
           !hasProgressControl,
           let subcommand,
           let subcommandIndex,
           GitCommandDispatch.supportsProgress(subcommand) {
            workingArgv.insert("--progress", at: subcommandIndex + 1)
        }
        if !hasPipeOrRedirect && !hasColorFlag {
            workingArgv.insert("--color=always", at: 1)
        }

        var result = workingArgv.map { posixShellEscapeForIOSSystem($0) }.joined(separator: " ")

        let hasNoPager = argv.contains("--no-pager")
        if let sub = subcommand,
           gitPagedSubcommands.contains(sub),
           !hasNoPager,
           !hasPipeOrRedirect {
            result += " | bat --paging=always --color=never --style=plain --wrap=never"
        }

        return result
    }

    /// POSIX single-quote escaping for ios_system. Mirrors the behaviour of
    /// `ShellInterpreter.shellEscape` — simple strings round-trip unchanged,
    /// `name=value` words only quote the value, and any embedded `'` becomes
    /// `'\''`. ios_system's POSIX tokeniser handles this encoding.
    nonisolated static func posixShellEscapeForIOSSystem(_ s: String) -> String {
        let specials: Set<Character> = [
            " ", "\t", "\n", "\"", "'", "\\", "|", "&", ";", "<", ">",
            "(", ")", "$", "`", "!", "{", "}", "*", "?", "[", "]", "#", "~"
        ]
        if !s.contains(where: { specials.contains($0) }) { return s }
        if let eqIdx = s.firstIndex(of: "=") {
            let name = String(s[s.startIndex..<eqIdx])
            if isValidShellIdentifier(name) {
                let value = String(s[s.index(after: eqIdx)...])
                let escapedValue = "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
                return name + "=" + escapedValue
            }
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// POSIX shell identifier rules: starts with letter/underscore, then
    /// letters/digits/underscores. Matches
    /// `ShellInterpreter.isValidShellIdentifier`.
    nonisolated static func isValidShellIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        guard first == "_" ||
              (first >= "A" && first <= "Z") ||
              (first >= "a" && first <= "z") else { return false }
        return s.unicodeScalars.dropFirst().allSatisfy { c in
            c == "_" ||
            (c >= "A" && c <= "Z") ||
            (c >= "a" && c <= "z") ||
            (c >= "0" && c <= "9")
        }
    }

    /// argv-based twin of `LocalShellSession+Git.gitCommandNeedsInterception`.
    /// Mirrors the same rules — bare `git`, auth flags, and `git commit`
    /// without a message need the native interactive handler; everything else
    /// is safe to delegate to ios_system. Operating on argv (not the raw
    /// string) means substitution output containing whitespace or quotes
    /// doesn't corrupt the check.
    nonisolated static func gitArgvNeedsInterception(_ argv: [String]) -> Bool {
        guard argv.count >= 2 else { return true }

        for token in argv {
            if token == "--ssh-key" || token == "--password" || token == "--profile" {
                return true
            }
            if token.hasPrefix("--ssh-key=") || token.hasPrefix("--profile=") {
                return true
            }
        }

        var subcommand: String?
        var idx = 1
        while idx < argv.count {
            let token = argv[idx]
            if token == "-C" || token == "--git-dir" || token == "--ssh-key" || token == "--profile" {
                idx += 2
                continue
            }
            if token.hasPrefix("--") || (token.hasPrefix("-") && token.count > 1) {
                idx += 1
                continue
            }
            subcommand = token
            break
        }

        if subcommand == "commit" {
            for token in argv {
                if token == "-m" || token.hasPrefix("-m") ||
                   token == "--message" || token.hasPrefix("--message=") {
                    return false
                }
            }
            return true
        }

        return false
    }

    /// An argv entry is "simple" (safe to space-join without shell quoting) iff
    /// it contains no shell metacharacter or whitespace. Matches the trigger
    /// set in `ShellInterpreter.shellEscape`.
    nonisolated static func argvEntryIsSimpleForNativeRoute(_ s: String) -> Bool {
        if s.isEmpty { return false }
        let specials: Set<Character> = [
            " ", "\t", "\n", "\"", "'", "\\", "|", "&", ";", "<", ">",
            "(", ")", "$", "`", "!", "{", "}", "*", "?", "[", "]", "#", "~"
        ]
        return !s.contains(where: { specials.contains($0) })
    }

    /// Build a throwaway `ShellInterpreter` wired to this session's shared
    /// environment and external/capture backends, used only for pre-routing
    /// expansion of simple commands.
    nonisolated func makeRoutingExpansionInterpreter() -> ShellInterpreter {
        let routingLFNormalizer = LFNormalizer()
        return ShellInterpreter(
            environment: sharedShellEnvironment,
            cancellationToken: scriptCancellationToken,
            executeExternal: { [weak self] command -> Int32 in
                guard let self else { return 127 }
                return self.runScriptExternalCommand(command)
            },
            captureExternal: { [weak self] command -> (Int32, String) in
                guard let self else { return (127, "") }
                return self.captureCommandOutput(command)
            },
            streamExternal: { [weak self] command, inputProvider, outputSink -> Int32 in
                guard let self else { return 127 }
                return self.streamExternalCommand(command, inputProvider: inputProvider, outputSink: outputSink)
            },
            canStreamExternalCommand: { [weak self] command -> Bool in
                guard let self else { return false }
                return self.canStreamExternalPipelineCommand(command)
            },
            backgroundStreamExternal: makeBackgroundStreamExternal(),
            writeOutput: { [weak self] data in
                guard let self else { return }
                self.outputBatcher.enqueue(routingLFNormalizer.normalize(data))
            },
            readLine: { [weak self] prompt, silent -> String? in
                guard let self else { return nil }
                return self.blockingReadFromTerminal(prompt: prompt, silent: silent)
            }
        )
    }

    /// Tokenize a command string into plain-text words using quote-aware splitting.
    private static func tokenizeToWords(_ command: String) -> [String] {
        let tokenizer = ShellTokenizer(source: command)
        var words: [String] = []
        while true {
            let token = tokenizer.next()
            switch token {
            case .word(let text):
                words.append(stripPUAMarkers(text))
            case .assignmentWord(let name, let value):
                words.append("\(name)=\(stripPUAMarkers(value))")
            case .eof:
                return words
            default:
                break
            }
        }
    }

    // MARK: - Traceroute Conversion

    /// Convert traceroute command to equivalent mtr report-mode command.
    /// `traceroute host` → `mtr -r -c 3 host`, `traceroute6 host` → `mtr6 -r -c 3 host`
    func convertTracerouteToMtr(_ command: String) -> String {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return "mtr -r -c 3" }
        let isIPv6 = tokens[0].lowercased() == "traceroute6"
        var parts: [String] = [isIPv6 ? "mtr6" : "mtr", "-r", "-c", "3"]
        parts.append(contentsOf: tokens.dropFirst())
        return parts.joined(separator: " ")
    }

    // MARK: - Mtr Report Flag Detection

    /// Check if an mtr command contains report-mode flags (non-interactive).
    /// Used to decide whether to route through ios_system (supports redirections/pipes)
    /// or the direct terminal path (interactive TUI).
    /// Handles combined short flags like `-wzc` (contains `-w` report flag).
    private func mtrCommandHasReportFlags(_ command: String) -> Bool {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let reportLongFlags: Set<String> = [
            "--report", "--report-wide", "--csv", "--json", "--xml", "--raw"
        ]
        let reportShortChars: Set<Character> = ["r", "w", "C", "j", "x", "l"]

        for token in tokens {
            if reportLongFlags.contains(token) { return true }
            if token.hasPrefix("-") && !token.hasPrefix("--") {
                // Short flag group: check each character for report flags.
                // Safe because no value-consuming flags (c,i,s,f,m,B,Q,G,o,y,P)
                // overlap with report flags (r,w,C,j,x,l).
                for char in token.dropFirst() {
                    if reportShortChars.contains(char) { return true }
                }
            }
        }
        return false
    }
}

#endif // !targetEnvironment(macCatalyst)
