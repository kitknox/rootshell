#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    // MARK: - Shared Host Tab Completion

    /// Handle tab completion for any SSH-family command using extracted destination.
    func handleHostTabCompletion(state: inout HostCompletionState, extraction: ExtractionResult) {
        // Only complete when cursor is on the destination
        guard extraction.context == .inDestination else {
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
            return
        }

        _ = state.handleTabTiming()

        // Get suggestions if cache is empty
        if state.suggestions.isEmpty {
            state.suggestions = QuickConnectSuggestionProvider.shared.getSuggestions(
                matching: extraction.completableText,
                mode: state.matchingMode,
                context: .sshDestination
            )
            state.suggestionIndex = 0
        }

        guard let suggestion = state.nextSuggestion() else {
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
            return
        }

        lineEditor.setBuffer("\(extraction.bufferPrefix)\(suggestion.completionString)")
        clearGhostText()
        redrawLine()
    }

    /// Update ghost text for any SSH-family command using extracted destination.
    private func updateHostGhostText(extraction: ExtractionResult) {
        guard extraction.context == .inDestination,
              !extraction.completableText.isEmpty else {
            currentGhostText = ""
            return
        }

        let suggestions = QuickConnectSuggestionProvider.shared.getSuggestions(
            matching: extraction.completableText,
            mode: .prefix,
            context: .sshDestination
        )

        guard let firstSuggestion = suggestions.first else {
            currentGhostText = ""
            return
        }

        let completion = firstSuggestion.completionString
        let lowerCompletion = completion.lowercased()
        let lowerInput = extraction.completableText.lowercased()

        if lowerCompletion.hasPrefix(lowerInput) {
            let suffixStart = completion.index(completion.startIndex, offsetBy: extraction.completableText.count)
            currentGhostText = String(completion[suffixStart...])
        } else {
            currentGhostText = ""
        }
    }

    // MARK: - Command-specific entry points (tab completion)

    /// Handle tab completion for SSH commands
    func handleSSHTabCompletion() {
        let extraction = CommandArgumentExtractor.extractDestination(
            buffer: lineEditor.buffer, commandLength: 4, flagSpec: .ssh
        )
        handleHostTabCompletion(state: &sshCompletion, extraction: extraction)
    }

    /// Handle tab completion for SFTP commands
    func handleSFTPTabCompletion() {
        let extraction = CommandArgumentExtractor.extractDestination(
            buffer: lineEditor.buffer, commandLength: 5, flagSpec: .sftp
        )
        handleHostTabCompletion(state: &sftpCompletion, extraction: extraction)
    }

    /// Handle tab completion for mosh/roam commands
    func handleMoshTabCompletion() {
        let buffer = lineEditor.buffer
        let lowerBuffer = buffer.lowercased()
        let commandLength: Int
        if lowerBuffer.hasPrefix("mosh ") { commandLength = 5 }
        else if lowerBuffer.hasPrefix("roam ") { commandLength = 5 }
        else { return }

        let extraction = CommandArgumentExtractor.extractDestination(
            buffer: buffer, commandLength: commandLength, flagSpec: .mosh
        )
        handleHostTabCompletion(state: &moshCompletion, extraction: extraction)
    }

    /// Handle tab completion for tssh/trzsz commands
    func handleTrzszTabCompletion() {
        let buffer = lineEditor.buffer
        let lowerBuffer = buffer.lowercased()
        let commandLength: Int
        if lowerBuffer.hasPrefix("tssh ") { commandLength = 5 }
        else if lowerBuffer.hasPrefix("trzsz ") { commandLength = 6 }
        else { return }

        let extraction = CommandArgumentExtractor.extractDestination(
            buffer: buffer, commandLength: commandLength, flagSpec: .trzsz
        )
        handleHostTabCompletion(state: &trzszCompletion, extraction: extraction)
    }

    /// Handle tab completion for ssh-copy-id commands
    func handleSSHCopyIDTabCompletion() {
        let extraction = CommandArgumentExtractor.extractDestination(
            buffer: lineEditor.buffer, commandLength: 12, flagSpec: .sshCopyID
        )
        handleHostTabCompletion(state: &sshCopyIDCompletion, extraction: extraction)
    }

    // MARK: - Ghost Text

    /// Update ghost text for SSH, SCP, SFTP, Mosh, Trzsz, or ssh-copy-id commands.
    /// This is the main entry point - routes to appropriate handler.
    func updateGhostText() {
        let buffer = lineEditor.buffer
        let lowerBuffer = buffer.lowercased()

        // Don't show ghost text if cursor is not at end
        guard lineEditor.cursorPosition == buffer.count else {
            currentGhostText = ""
            return
        }

        if lowerBuffer.hasPrefix("ssh ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 4, flagSpec: .ssh
            ))
        } else if lowerBuffer.hasPrefix("mosh ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 5, flagSpec: .mosh
            ))
        } else if lowerBuffer.hasPrefix("roam ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 5, flagSpec: .mosh
            ))
        } else if lowerBuffer.hasPrefix("sftp ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 5, flagSpec: .sftp
            ))
        } else if lowerBuffer.hasPrefix("tssh ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 5, flagSpec: .trzsz
            ))
        } else if lowerBuffer.hasPrefix("trzsz ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 6, flagSpec: .trzsz
            ))
        } else if lowerBuffer.hasPrefix("ssh-copy-id ") {
            updateHostGhostText(extraction: CommandArgumentExtractor.extractDestination(
                buffer: buffer, commandLength: 12, flagSpec: .sshCopyID
            ))
        } else if lowerBuffer.hasPrefix("scp ") {
            updateSCPGhostText()
        } else if lowerBuffer == "ssh" || lowerBuffer == "mosh" || lowerBuffer == "roam" ||
                  lowerBuffer == "sftp" || lowerBuffer == "tssh" || lowerBuffer == "trzsz" ||
                  lowerBuffer == "scp" || lowerBuffer == "ssh-copy-id" {
            // Just the command name without space - no ghost text
            currentGhostText = ""
        } else {
            currentGhostText = ""
        }
    }

    /// Clear ghost text (called when accepting completion or on certain actions)
    func clearGhostText() {
        currentGhostText = ""
    }

    // MARK: - SCP Tab Completion

    /// Handle tab completion for SCP commands.
    /// Uses CommandArgumentExtractor for flag skipping, then combines SSH host + file completions.
    func handleSCPTabCompletion() {
        let buffer = lineEditor.buffer
        guard buffer.lowercased().hasPrefix("scp ") else { return }

        let extraction = CommandArgumentExtractor.extractLastPositional(
            buffer: buffer, commandLength: 4, flagSpec: .scp
        )

        // SCP supports completion in destination context only
        guard extraction.context == .inDestination else {
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
            return
        }

        _ = scpCompletion.handleTabTiming()

        if scpCompletion.suggestions.isEmpty {
            scpCompletion.suggestions = getSCPCompletions(
                for: extraction.completableText, bufferPrefix: extraction.bufferPrefix)
            scpCompletion.suggestionIndex = 0
        }

        guard let suggestion = scpCompletion.nextSuggestion() else {
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
            return
        }

        lineEditor.setBuffer("\(extraction.bufferPrefix)\(suggestion.insertText)")
        clearGhostText()
        redrawLine()
    }

    /// Get combined SCP completions (local files first, then SSH hosts)
    private func getSCPCompletions(for prefix: String, bufferPrefix: String) -> [SCPCompletionItem] {
        var completions: [SCPCompletionItem] = []
        var seen = Set<String>()

        // Local file completions first — `cp` mental model: a bare prefix means a local path.
        // Uses encoded matches so spaces/quotes are handled the same way as `cp <tab>`.
        let fileMatches = completionProvider.getEncodedPathMatches(
            line: "_ " + prefix,
            cursorPosition: 2 + prefix.count,
            workingDirectory: sessionCurrentDirectory
        )
        for match in fileMatches {
            let key = match.rawPath.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                // matchText stays raw so updateSCPGhostText can prefix-match against the user's literal typing.
                completions.append(SCPCompletionItem(matchText: match.rawPath, insertText: match.insertText))
            }
        }

        // SSH host suggestions (with : appended for SCP format), only if prefix isn't already a remote spec.
        if !prefix.contains(":") {
            let hasPFlag = bufferPrefix.lowercased().contains(" -p ")
                || bufferPrefix.lowercased().contains(" -p\t")

            let rawHostSuggestions = QuickConnectSuggestionProvider.shared
                .getSuggestions(matching: prefix, mode: scpCompletion.matchingMode, context: .sshDestination)

            // ProfileSuggestion.matches() always uses substring across name/host/username/folder/tags/notes,
            // ignoring `mode`. In .prefix mode that lets a profile whose tag/notes contains "ni" surface its
            // unrelated host (e.g., `administrator@10.10.10.37`) for input `NI`. Re-filter profile suggestions
            // here so they pass only when the profile's name (displayString) or `user@host` (completionString)
            // truly prefix-matches. Other source types already enforce prefix matching against their primary
            // identifiers (history displayString, cloud label/IP/hostname, local-network serviceName/hostname)
            // inside their own matches(_:mode:), so don't second-guess them — that's what dropped legitimate
            // label-prefix matches like `web<Tab>` → `root@10.0.0.5` for a cloud VM labeled `web-1`.
            let lowerPrefix = prefix.lowercased()
            let hostSuggestions: [AnyQuickConnectSuggestion]
            if scpCompletion.matchingMode == .prefix {
                hostSuggestions = rawHostSuggestions.filter { s in
                    if s.sourceType == .profile {
                        return s.displayString.lowercased().hasPrefix(lowerPrefix)
                            || s.completionString.lowercased().hasPrefix(lowerPrefix)
                    }
                    return true
                }
            } else {
                hostSuggestions = rawHostSuggestions
            }

            for suggestion in hostSuggestions {
                let raw = suggestion.completionString
                let matchText = raw + ":"

                let insertText: String
                if !hasPFlag, let parsed = parseSCPHostPort(raw) {
                    insertText = "-P \(parsed.port) \(parsed.userAtHost):"
                } else {
                    // Standard port or -P already present — strip port suffix if present
                    if let parsed = parseSCPHostPort(raw) {
                        insertText = parsed.userAtHost + ":"
                    } else {
                        insertText = matchText
                    }
                }

                let key = matchText.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    completions.append(SCPCompletionItem(matchText: matchText, insertText: insertText))
                }
            }
        }

        return completions
    }

    /// Parse a completion string to extract host and port components for SCP formatting.
    /// Returns (userAtHost, port) if non-standard port detected, nil otherwise.
    private func parseSCPHostPort(_ completionString: String) -> (userAtHost: String, port: Int)? {
        // Skip HSS shorthands and jump host entries
        guard !completionString.hasPrefix("!"),
              !completionString.contains(" via ") else { return nil }

        guard let atIndex = completionString.lastIndex(of: "@") else { return nil }
        let afterAt = completionString[completionString.index(after: atIndex)...]

        guard let colonIndex = afterAt.lastIndex(of: ":") else { return nil }
        let portStr = String(afterAt[afterAt.index(after: colonIndex)...])

        guard let port = Int(portStr), port > 0, port <= 65535 else { return nil }

        let userAtHost = String(completionString[..<colonIndex])
        return (userAtHost, port)
    }

    /// Update ghost text based on current SCP command input
    private func updateSCPGhostText() {
        let buffer = lineEditor.buffer

        let extraction = CommandArgumentExtractor.extractLastPositional(
            buffer: buffer, commandLength: 4, flagSpec: .scp
        )

        guard extraction.context == .inDestination,
              !extraction.completableText.isEmpty else {
            currentGhostText = ""
            return
        }

        let suggestions = getSCPCompletions(
            for: extraction.completableText, bufferPrefix: extraction.bufferPrefix)

        guard let firstSuggestion = suggestions.first else {
            currentGhostText = ""
            return
        }

        let lowerCompletion = firstSuggestion.matchText.lowercased()
        let lowerPrefix = extraction.completableText.lowercased()

        if lowerCompletion.hasPrefix(lowerPrefix) {
            let suffixStart = firstSuggestion.matchText.index(
                firstSuggestion.matchText.startIndex,
                offsetBy: extraction.completableText.count
            )
            currentGhostText = String(firstSuggestion.matchText[suffixStart...])
        } else {
            currentGhostText = ""
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
