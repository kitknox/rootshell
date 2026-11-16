#if !targetEnvironment(macCatalyst)

import Foundation
import os
import OSLog

private struct ScreenControlDetector: Sendable {
    private var pendingEsc = false
    private var inCSI = false

    nonisolated init() {}

    nonisolated mutating func scan(_ data: Data) -> Bool {
        for byte in data {
            if inCSI {
                if byte >= 0x40 && byte <= 0x7E {
                    inCSI = false
                    if byte != 0x6D { // 'm' (SGR)
                        return true
                    }
                }
                continue
            }

            if pendingEsc {
                pendingEsc = false
                if byte == 0x5B { // '['
                    inCSI = true
                    continue
                }
            }

            if byte == 0x1B { // ESC
                pendingEsc = true
            }
        }

        return false
    }
}

private struct SendableBox<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T

    nonisolated init(_ value: T) {
        self.value = value
    }
}

extension LocalShellSession {
    /// Checks if data appears to be a terminal response (cursor position report, etc.)
    /// Terminal responses are escape sequences that the terminal sends back to the application
    /// in response to queries. Common patterns:
    /// - Cursor Position Report: ESC[row;colR  (e.g., "\x1b[1;2R")
    /// - Device Attributes: ESC[...c
    nonisolated func isTerminalResponse(_ data: Data) -> Bool {
        guard data.count >= 4,
              data[0] == 0x1B, // ESC
              data[1] == 0x5B  // [
        else {
            return false
        }

        // Cursor position report ends with 'R': ESC [ row ; col R
        if let lastByte = data.last, lastByte == 0x52 { // 'R'
            return true
        }

        // Device attributes response ends with 'c'
        if let lastByte = data.last, lastByte == 0x63 { // 'c'
            return true
        }

        return false
    }

    // MARK: - Cooked-stdin heuristics

    /// Decides whether the Swift terminal layer should run a cooked-mode stdin loop
    /// (local echo, line buffering, Ctrl-D → EOF) for the given command string.
    ///
    /// ios_system pipes every command's stdin through a raw pipe, not a TTY, so
    /// there is no kernel cooked mode. For filters that read stdin when invoked
    /// with no file argument (bat, cat, grep, awk, ...), the user sees nothing
    /// unless we echo and forward here. Only arm cooked mode for an allow-list of
    /// known stdin-consuming commands, and only when the command has no upstream
    /// pipe / redirect and no file positional argument.
    nonisolated func shouldUseCookedStdin(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if Self.containsUnquotedShellOperator(trimmed) { return false }

        let tokens = Self.tokenizeShellArgs(trimmed)
        guard let argv0 = tokens.first else { return false }
        let name = (argv0 as NSString).lastPathComponent

        var positionalCount = 0
        var afterDoubleDash = false
        for tok in tokens.dropFirst() {
            if afterDoubleDash {
                positionalCount += 1
                continue
            }
            if tok == "--" { afterDoubleDash = true; continue }
            if tok.hasPrefix("-") && tok != "-" { continue }
            positionalCount += 1
        }

        switch name {
        // Always reads stdin regardless of positional args.
        case "tr", "tee":
            return true
        // Pattern/script as first positional; any further positional is a file → not cooked.
        case "grep", "egrep", "fgrep", "awk", "sed":
            return positionalCount <= 1
        // Reads stdin only when invoked with no file positional.
        case "bat", "cat", "sort", "uniq", "wc", "head", "tail",
             "base64", "md5", "sha1sum", "sha256sum",
             "fold", "nl", "rev", "jq", "column", "expand", "unexpand", "pr":
            return positionalCount == 0
        default:
            return false
        }
    }

    /// True if the string contains any shell structural operator outside quotes.
    /// Conservative: a match means "don't arm cooked mode"; false positives are OK.
    nonisolated private static func containsUnquotedShellOperator(_ s: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var escaped = false
        for ch in s {
            if escaped { escaped = false; continue }
            if ch == "\\" && !inSingle { escaped = true; continue }
            if inSingle {
                if ch == "'" { inSingle = false }
                continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false }
                continue
            }
            switch ch {
            case "'": inSingle = true
            case "\"": inDouble = true
            case "|", "<", ">", "&", ";", "`", "(", ")":
                return true
            default: break
            }
        }
        return false
    }

    /// Minimal shell-style tokenizer: splits on unquoted whitespace, honors
    /// single / double quotes and backslash escapes. Not a full shell parser —
    /// we only need enough to pull out argv[0] and count positionals.
    nonisolated private static func tokenizeShellArgs(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        var started = false
        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
                started = true
                continue
            }
            if ch == "\\" && !inSingle {
                escaped = true
                continue
            }
            if inSingle {
                if ch == "'" { inSingle = false } else { current.append(ch) }
                continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false } else { current.append(ch) }
                continue
            }
            if ch.isWhitespace {
                if started {
                    tokens.append(current)
                    current = ""
                    started = false
                }
                continue
            }
            if ch == "'" { inSingle = true; started = true; continue }
            if ch == "\"" { inDouble = true; started = true; continue }
            current.append(ch)
            started = true
        }
        if started { tokens.append(current) }
        return tokens
    }

    // MARK: - ios_system setup

    /// Configures ios_system for this session
    func setupIOSSystemSession() {
        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)

        // Switch to our session context
        ios_switchSession(sessionPtr)

        // Set environment variables
        ios_setenv("TERM", TerminalTypeSettings.local, 1)

        // Point ncurses-linked tools at the bundled terminfo so xterm-ghostty
        // resolves. Lookups of other names still fall through to the system
        // database, so this is safe regardless of the configured TERM.
        if let terminfoPath = TerminalTypeSettings.terminfoPath {
            ios_setenv("TERMINFO", terminfoPath, 1)
        }

        // Set locale from system preferences (avoids iOS regional modifiers)
        // Only set LANG (not LC_ALL) to allow customization of individual LC_* categories
        if let effectiveLocale = LocaleHelper.effectiveLocale {
            ios_setenv("LANG", effectiveLocale, 1)
        }

        // Set terminal identification for apps that check capabilities
        // Apps like Claude Code use TERM_PROGRAM to detect notification support
        ios_setenv("TERM_PROGRAM", "ghostty", 1)
        ios_setenv("TERM_PROGRAM_VERSION", TerminalIdentity.shortVersion, 1)
        ios_setenv("COLORTERM", "truecolor", 1)

        // Product identity, in the one namespace that survives SSH to a remote host
        for envVar in TerminalIdentity.forwardedVariables {
            ios_setenv(envVar.name, envVar.value, 1)
        }

        // Set HOME to Documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        ios_setenv("HOME", documentsPath, 1)

        // Set SSL certificate file path for curl HTTPS support
        if let cacertPath = CurlResourceManager.shared.cacertPath {
            ios_setenv("SSL_CERT_FILE", cacertPath, 1)
        }

        // Set VIMRUNTIME for vim syntax highlighting and runtime files
        if let vimRuntimePath = Bundle.main.path(forResource: "VimRuntime", ofType: "bundle") {
            ios_setenv("VIMRUNTIME", "\(vimRuntimePath)/Contents/Resources/vim", 1)
        }

        // Configure bat (syntax-highlighted cat) for iOS
        ios_setenv("BAT_PAGING", "always", 1)    // Enable paging (bridge handles it via minus)
        ios_setenv("BAT_THEME", "terminal", 1)   // Use "terminal" theme (built from palette)
        Self.updateBatTerminalPalette()

        // Set ios_system's mini root FIRST — ios_setMiniRoot resets the session's
        // currentDir to the mini root path, so it must be called before ios_setDirectoryURL.
        ios_setMiniRoot(documentsPath)

        // Set current working directory via ios_setDirectoryURL (updates both the OS CWD
        // and the per-session currentDir in ios_system's sessionParameters struct).
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var initialCwd = documentsPath
        if let savedCwd = currentWorkingDirectory {
            if FileManager.default.fileExists(atPath: savedCwd) {
                ios_setDirectoryURL(URL(fileURLWithPath: savedCwd))
                initialCwd = savedCwd
            } else if let resolved = Self.resolveContainerPath(savedCwd, currentDocumentsPath: documentsPath),
                      FileManager.default.fileExists(atPath: resolved) {
                // Container UUID changed between launches — rewrite path prefix
                ios_setDirectoryURL(URL(fileURLWithPath: resolved))
                initialCwd = resolved
                currentWorkingDirectory = resolved
            } else {
                ios_setDirectoryURL(documentsURL)
            }
        } else {
            ios_setDirectoryURL(documentsURL)
        }
        ios_setenv("PWD", initialCwd, 1)

        // Configure bookmarked external locations for shell access
        BookmarkedLocationsManager.shared.configureIOSSystem()

        // Set initial window size
        let size = pty.windowSize
        ios_setWindowSize(Int32(size.cols), Int32(size.rows), sessionPtr)

        // Set COLUMNS and LINES for programs that check env vars
        ios_setenv("COLUMNS", String(size.cols), 1)
        ios_setenv("LINES", String(size.rows), 1)

        // ios_system resolves bundled commands from its command dictionary;
        // PATH is only needed to find user-installed scripts and tools.
        var paths = [
            documentsPath,
            "\(documentsPath)/bin"
        ]
        // The simulator can read the Mac's /usr/bin/cd (a #!/bin/sh script).
        // ios_system gives PATH scripts precedence over its builtins and tries
        // to launch that script with dash, which we don't bundle. Keep host
        // tools out of the simulator's PATH so cd and other builtins resolve
        // exactly as they do on a device.
        #if !targetEnvironment(simulator)
        paths += [
            "/usr/bin",
            "/bin",
            "/usr/local/bin"
        ]
        #endif
        ios_setenv("PATH", paths.joined(separator: ":"), 1)
    }

    /// Execute a command using ios_system
    nonisolated func runExternalCommand(_ command: String) {
        // A command queued behind teardown must not launch on the dead session
        guard !hasStopped else { return }

        // Names the command for the pane's logo and Running card; the clear
        // goes out after its output, just before the prompt.
        if let report = ShellProgramReportEncoder.commandStarted(commandLine: command) {
            Task { @MainActor [weak self] in self?.onOutput?(report) }
        }

        // Reset interactive state for new command
        // This will be set to true if the command outputs cursor control sequences
        interactiveLock.withLock {
            isCurrentCommandInteractive = false
        }

        // Reset full-screen command state for new command
        let wasFullScreen = fullScreenLock.withLock {
            let old = isFullScreenCommand
            isFullScreenCommand = false
            return old
        }
        if wasFullScreen {
            Task { @MainActor [weak self] in
                self?.notifyLocalTaskStateIfNeeded()
            }
        }

        // Reset output normalization for new command
        outputNormalizationLock.withLock {
            shouldNormalizeOutput = true
        }

        // Create pipes for capturing output
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]

        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            Task { @MainActor [weak self] in
                guard let session = self else { return }
                session.onOutput?(session.normalizeLineEndings("Error: Failed to create pipes\n"))
                session.displayPrompt()
            }
            return
        }

        // Store stdin write FD and switch to command stdin forwarding mode.
        // This allows user input to be forwarded directly to the running command.
        // For known stdin-consuming filters with no file arg (bat, cat, ...), also
        // arm cooked-mode so the terminal echoes typed chars and commits lines.
        let cooked = shouldUseCookedStdin(command)
        stdinLock.withLock {
            commandStdinWriteFd = stdinPipe[1]
            inputMode = .commandStdin
            cookedStdinActive = cooked
            cookedLineBuffer.removeAll(keepingCapacity: true)
        }

        Self.logger.debug("[stdin] Switched to commandStdin mode, writeFd=\(stdinPipe[1]), cooked=\(cooked)")

        // Set read ends to non-blocking mode for concurrent monitoring
        let stdoutReadFd = stdoutPipe[0]
        let stderrReadFd = stderrPipe[0]
        let currentStdoutFlags = fcntl(stdoutReadFd, F_GETFL)
        let currentStderrFlags = fcntl(stderrReadFd, F_GETFL)

        if fcntl(stdoutReadFd, F_SETFL, currentStdoutFlags | O_NONBLOCK) == -1 ||
            fcntl(stderrReadFd, F_SETFL, currentStderrFlags | O_NONBLOCK) == -1 {
            // Reset stdin mode on error
            stdinLock.withLock {
                commandStdinWriteFd = -1
                inputMode = .lineEditor
                cookedStdinActive = false
                cookedLineBuffer.removeAll(keepingCapacity: true)
            }

            close(stdinPipe[0])
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
            Task { @MainActor [weak self] in
                guard let session = self else { return }
                session.onOutput?(session.normalizeLineEndings("Error: Failed to set non-blocking mode\n"))
                session.displayPrompt()
            }
            return
        }

        // Create FILE* from pipes
        // stdin: read end for command, write end for us (now used for interactive input!)
        // stdout/stderr: write end for command, read end for us
        guard let stdinFile = fdopen(stdinPipe[0], "r"),
              let stdoutFile = fdopen(stdoutPipe[1], "w"),
              let stderrFile = fdopen(stderrPipe[1], "w") else {
            // Reset stdin mode on error
            stdinLock.withLock {
                commandStdinWriteFd = -1
                inputMode = .lineEditor
                cookedStdinActive = false
                cookedLineBuffer.removeAll(keepingCapacity: true)
            }

            close(stdinPipe[0])
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
            Task { @MainActor [weak self] in
                guard let session = self else { return }
                session.onOutput?(session.normalizeLineEndings("Error: Failed to create FILE streams\n"))
                session.displayPrompt()
            }
            return
        }

        // Set unbuffered mode for immediate I/O
        setvbuf(stdinFile, nil, _IONBF, 0)
        setvbuf(stdoutFile, nil, _IONBF, 0)
        setvbuf(stderrFile, nil, _IONBF, 0)

        // DispatchGroup tracks when both pipe read sources have hit EOF
        let monitorGroup = DispatchGroup()
        let batcher = outputBatcher

        // Start DispatchSource-based monitoring for stdout and stderr
        let stdoutSource = makePipeReadSource(fd: stdoutReadFd, name: "stdout", group: monitorGroup, batcher: batcher)
        let stderrSource = makePipeReadSource(fd: stderrReadFd, name: "stderr", group: monitorGroup, batcher: batcher)

        // IMPORTANT: Switch session context BEFORE setting streams
        // This ensures streams are set for the correct session
        let sessionPtr = IOSSystemSessionKey.key(for: self.sessionID)
        ios_switchSession(sessionPtr)

        // Refresh custom display username before each command (picks up settings changes)
        let customUsername = UserPreferences.effectiveUsername
        if customUsername != NSUserName() {
            ios_setenv("ROOTSHELL_USERNAME", customUsername, 1)
        } else {
            ios_unsetenv("ROOTSHELL_USERNAME")
        }
        #if !CHINA_BUILD
        Self.refreshTailnetProxyEnvironment()
        #endif

        // Redirect ios_system I/O to pipes. stdout and stderr get distinct
        // streams so top-level `2>` redirections can actually separate them —
        // both drain into the same batcher, so on-screen output is unchanged.
        // (Historically merged "like Blink"; revert to merged if any command's
        // redirection handling regresses.)
        ios_setStreams(stdinFile, stdoutFile, stderrFile)

        // Create TTY for proper shell behavior (enables password prompts, vim, less, etc.)
        // Pattern from Blink: duplicate stdin FD to create a TTY FILE*
        let ttyFd = dup(fileno(stdinFile))
        let tty = fdopen(ttyFd, "rb")
        if tty != nil {
            ios_settty(tty)
        }

        // Configure async execution options
        var options = ios_async_default_options()
        options.input = stdinFile
        options.output = stdoutFile
        options.error = stderrFile
        options.session = UnsafeMutableRawPointer(mutating: sessionPtr)
        options.timeout_ms = -1  // No timeout

        Task { @MainActor in
            Self.logger.debug("Executing command asynchronously: '\(command)'")
        }

        // Execute command asynchronously
        let cmdHandle = ios_system_async(command, &options)

        // Store command handle and PID for interruption support
        pidLock.withLock {
            currentCommand = cmdHandle
            if let handle = cmdHandle {
                currentPid = ios_command_get_pid(handle)
            }
        }

        // Wait for command to complete (blocks commandQueue but allows stdin forwarding on other threads)
        var result: Int32 = -1
        if let handle = cmdHandle {
            result = ios_command_wait(handle)

            // Clear command handle BEFORE releasing to prevent force-kill timer
            // from reading a stale (freed) pointer
            pidLock.withLock {
                currentCommand = nil
                currentPid = nil
                forceKillScheduled = false
            }

            ios_command_release(handle)
        }
        let exitCode = result

        Task { @MainActor in
            Self.logger.debug("Command completed with exit code: \(exitCode)")
        }

        // Clean up stdin forwarding state BEFORE closing pipes
        let stdinWriteFd = stdinLock.withLock {
            let fd = commandStdinWriteFd
            commandStdinWriteFd = -1
            inputMode = .lineEditor
            cookedStdinActive = false
            cookedLineBuffer.removeAll(keepingCapacity: true)
            return fd
        }

        Self.logger.debug("[stdin] Switched back to lineEditor mode")

        // Reset interactive state
        interactiveLock.withLock {
            isCurrentCommandInteractive = false
        }

        // Reset full-screen command state and notify if it was active
        let wasFullScreenAtEnd = fullScreenLock.withLock {
            let old = isFullScreenCommand
            isFullScreenCommand = false
            return old
        }
        if wasFullScreenAtEnd {
            Task { @MainActor [weak self] in
                self?.notifyLocalTaskStateIfNeeded()
            }
        }

        // Close stdin write end (signals EOF to command if it's still reading)
        if stdinWriteFd >= 0 {
            close(stdinWriteFd)
        }

        // Close TTY and reset session's tty pointer immediately to prevent double-close
        if tty != nil {
            fclose(tty)
            ios_settty(nil)
        }

        // IMPORTANT: Reset session streams to standard streams BEFORE closing FILE*s.
        // This prevents ios_system from holding stale pointers to our FILE*s.
        // If ios_closeSession() is called later (e.g., when closing tab), ios_session_cleanup_params()
        // would try to fclose() them again. If the underlying FD was reused by another component
        // (e.g., SSH), iOS guards that FD and crashes with EXC_GUARD when we try to close it.
        ios_setStreams(stdin, stdout, stderr)

        // Flush and close streams - closing write ends signals EOF to monitoring tasks
        fflush(stdoutFile)
        fflush(stderrFile)
        fclose(stdinFile)  // Close stdin read end (used by command)
        fclose(stdoutFile)  // Close stdout write end - signals EOF to monitor
        fclose(stderrFile)  // Close stderr write end - signals EOF to monitor

        // Cancel sources and wait for cancel handlers to close FDs and leave the group.
        // The sources have been draining data in real-time throughout command execution.
        // By now (after ios_command_wait + cleanup), pipe buffers are already processed.
        // Cancel handlers run on each source's queue after any in-flight event handler,
        // so no concurrent read()/close() race is possible.
        // Wait is unbounded but completes in microseconds: read FDs are non-blocking so
        // event handlers can't block in read(), and cancel handlers are trivial.
        stdoutSource.cancel()
        stderrSource.cancel()
        monitorGroup.wait()

        // Flush batcher and display prompt AFTER all output is delivered
        // This ensures proper ordering: command output → prompt
        // flush() runs its completion on the batcher's serial queue — one MainActor hop to prompt
        let boxedSelf = SendableBox(self)
        let boxedCommand = SendableBox(command)
        batcher.flush { [boxedSelf, boxedCommand] in
            Task { @MainActor in
                let session = boxedSelf.value
                if exitCode != 0 {
                    Self.logger.debug("Command '\(boxedCommand.value)' exited with status: \(exitCode)")
                }
                session.lastCommandSucceeded = (exitCode == 0)
                // Record the real exit code so interactive `echo $?` works —
                // displayPrompt's sign-sync alone would degrade it to 0/1.
                session.sharedShellEnvironment.setLastExitCode(exitCode)
                // Invalidate prompt cache - directory may have changed (cd command)
                session.promptCache.invalidate()
                session.onOutput?(ShellProgramReportEncoder.commandEnded)
                session.displayPrompt(ensureAtLineStart: wasFullScreenAtEnd)

                // Replay type-ahead buffer through line editor
                if !session.typeAheadBuffer.isEmpty {
                    let buffered = session.typeAheadBuffer
                    session.typeAheadBuffer.removeAll()
                    if let text = String(data: buffered, encoding: .utf8) {
                        let count = buffered.count
                        Self.logger.debug("[stdin] Replaying \(count) bytes of type-ahead")
                        session.processInput(text)
                    }
                }
            }
        }
    }

    /// Creates a DispatchSource that monitors a pipe FD for output and feeds it to the batcher.
    /// The cancel handler closes the FD and leaves the group. Caller must cancel the source and
    /// wait on the group to ensure FDs are closed before proceeding.
    nonisolated func makePipeReadSource(
        fd: Int32,
        name: String,
        group: DispatchGroup,
        batcher: OutputBatcher
    ) -> DispatchSourceRead {
        group.enter()
        let readQueue = DispatchQueue(label: "com.rootshell.localshell.read.\(name)", qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)

        // Mutable state captured by the event handler closure (single-threaded on readQueue)
        var previousEndedWithCR = false
        var screenControlDetector = ScreenControlDetector()
        // Set by event handler on EOF/error so it stops processing before cancel handler runs
        var finished = false

        source.setEventHandler { [weak self] in
            guard !finished else { return }

            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while true {
                let bytesRead = read(fd, buffer, bufferSize)

                if bytesRead > 0 {
                    guard let self else { continue }
                    let chunk = Data(bytes: buffer, count: bytesRead)

                    var normalizeOutput = self.outputNormalizationLock.withLock { self.shouldNormalizeOutput }

                    if normalizeOutput && screenControlDetector.scan(chunk) {
                        self.outputNormalizationLock.withLock {
                            self.shouldNormalizeOutput = false
                        }
                        normalizeOutput = false
                        previousEndedWithCR = false

                        // Screen control detected (cursor movement, clear, etc. — NOT just colors).
                        // Mark as full-screen command for location diary background execution.
                        let wasFullScreen = self.fullScreenLock.withLock {
                            let old = self.isFullScreenCommand
                            self.isFullScreenCommand = true
                            return old
                        }
                        if !wasFullScreen {
                            Task { @MainActor [weak self] in
                                self?.notifyLocalTaskStateIfNeeded()
                            }
                        }

                        // A cooked filter that turned into a full-screen program is unusual,
                        // but flush any pending cooked line into the pipe and disarm cooked
                        // mode so subsequent input goes through the direct-forward path.
                        let (pending, fd) = self.stdinLock.withLock { () -> (Data, Int32) in
                            guard self.cookedStdinActive else { return (Data(), -1) }
                            let p = self.cookedLineBuffer
                            self.cookedLineBuffer.removeAll(keepingCapacity: true)
                            self.cookedStdinActive = false
                            return (p, self.commandStdinWriteFd)
                        }
                        if !pending.isEmpty, fd >= 0 {
                            pending.withUnsafeBytes { bufferPtr in
                                guard let baseAddress = bufferPtr.baseAddress else { return }
                                _ = Darwin.write(fd, baseAddress, pending.count)
                            }
                        }
                    }

                    let outputData = normalizeOutput
                    ? self.normalizePipeOutput(chunk, previousEndedWithCR: &previousEndedWithCR)
                    : chunk

                    // Mark command as interactive if we see any escape sequences.
                    if outputData.contains(0x1B) {
                        self.interactiveLock.withLock {
                            self.isCurrentCommandInteractive = true
                        }
                    }

                    batcher.enqueue(outputData)
                    continue

                } else if bytesRead == 0 {
                    // EOF — write end closed, command finished.
                    finished = true
                    return
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        // No more data right now — return to let kqueue wake us again
                        return
                    } else if err == EINTR {
                        continue
                    } else {
                        Self.logger.debug("Error reading from \(name) pipe: errno=\(err)")
                        finished = true
                        return
                    }
                }
            }
        }

        source.setCancelHandler { [weak self] in
            // Runs on readQueue after any in-flight event handler completes.
            // Drain any bytes still in the pipe buffer that the event handler didn't get to.
            let drainBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { drainBuf.deallocate() }
            while true {
                let n = read(fd, drainBuf, 4096)
                if n > 0, let self {
                    let chunk = Data(bytes: drainBuf, count: n)
                    let normalizeOutput = self.outputNormalizationLock.withLock { self.shouldNormalizeOutput }
                    let outputData = normalizeOutput
                        ? self.normalizePipeOutput(chunk, previousEndedWithCR: &previousEndedWithCR)
                        : chunk
                    batcher.enqueue(outputData)
                } else {
                    break  // EOF, EAGAIN, or error — nothing left
                }
            }
            close(fd)
            group.leave()
        }

        source.resume()
        return source
    }

    private nonisolated func normalizePipeOutput(_ data: Data, previousEndedWithCR: inout Bool) -> Data {
        // When running without a PTY, some tools will emit LF without CR.
        // Convert lone LF -> CRLF while preserving existing CRLF and standalone CR.
        var out = Data()
        out.reserveCapacity(data.count + (data.count / 16))

        var prevCR = previousEndedWithCR
        for byte in data {
            if byte == 0x0A { // LF
                if !prevCR { out.append(0x0D) }
                out.append(0x0A)
                prevCR = false
                continue
            }

            out.append(byte)
            prevCR = (byte == 0x0D)
        }
        previousEndedWithCR = prevCR

        // Fast-path: avoid extra allocations when no changes were needed.
        // If we never inserted CR, `out` will match `data` exactly.
        if out.count == data.count {
            return data
        }
        return out
    }

    /// Converts Unix line endings to terminal line endings
    func normalizeLineEndings(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")  // Normalize to \n first
            .replacingOccurrences(of: "\r", with: "\n")    // Convert any standalone \r to \n
            .replacingOccurrences(of: "\n", with: "\r\n")  // Convert all \n to \r\n
    }

    /// Like `normalizeLineEndings` but keeps a lone `\r`, so progress lines redraw in place.
    func normalizeNewlinesKeepingCR(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: - bat Theme Palette

    /// Push the current terminal palette into bat's global theme override.
    /// Called at session startup and on theme change.
    static func updateBatTerminalPalette() {
        let tc = SpinnerAnimator.ThemeColors.fromThemeManager()
        let fg = packRGB(tc.foreground)
        let bg = packRGB(tc.background)
        var palette: [UInt32] = (0..<16).map { packRGB(tc.palette[$0]) }
        palette.withUnsafeMutableBufferPointer { ptr in
            bat_set_terminal_palette(fg, bg, ptr.baseAddress)
        }
    }

    private static func packRGB(_ c: (UInt8, UInt8, UInt8)) -> UInt32 {
        UInt32(c.0) << 16 | UInt32(c.1) << 8 | UInt32(c.2)
    }

}

#if !CHINA_BUILD
extension LocalShellSession {
    /// Values this app last set, so a value the user exported is left alone.
    private nonisolated static let tailnetProxyOwned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Points curl at in-app Tailscale's loopback proxy (ALL_PROXY), or clears
    /// it. The environment is process-wide; this runs before each command.
    nonisolated static func refreshTailnetProxyEnvironment() {
        let wanted = TailnetRouting.shared.state.shellProxyEnvironment ?? [:]
        tailnetProxyOwned.withLock { owned in
            for name in ["ALL_PROXY", "NO_PROXY"] {
                let current = ios_getenv(name).map { String(cString: $0) }
                guard current == nil || current == owned[name] else { continue }
                if let value = wanted[name] {
                    if current != value { ios_setenv(name, value, 1) }
                    owned[name] = value
                } else if owned[name] != nil {
                    ios_unsetenv(name)
                    owned[name] = nil
                }
            }
        }
    }
}
#endif

#endif // !targetEnvironment(macCatalyst)
