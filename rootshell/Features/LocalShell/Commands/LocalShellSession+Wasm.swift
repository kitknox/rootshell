#if !targetEnvironment(macCatalyst)

import Foundation

struct WasmLaunchPlan: Sendable {
    let wasmURL: URL
    let argv: [String]
    let env: [String: String]
    let cwd: URL
    let sandboxRoot: URL
}

enum WasmPrepResult: Sendable {
    case ready(WasmLaunchPlan)
    case usage(String)
    case selfTest
    case error(String)
    case empty
}

extension LocalShellSession {
    /// Public entry point for `wasm <file> [args...]` and bare `*.wasm` commands.
    /// Mirrors the shape of `handlePingCommand`: sets session mode, runs the
    /// process, restores prompt on completion.
    func handleWasmCommand(_ command: String) {
        switch prepareWasmLaunch(command) {
        case .empty:
            displayPrompt()
            return

        case .usage(let msg):
            onOutput?(normalizeLineEndings(msg))
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            displayPrompt()
            return

        case .selfTest:
            runWasmSelfTest()
            return

        case .error(let msg):
            onOutput?(normalizeLineEndings("wasm: \(msg)\n"))
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            displayPrompt()
            return

        case .ready(let plan):
            let truncated = String((plan.wasmURL.lastPathComponent as NSString).lastPathComponent.prefix(30))
            onTitleChange?(truncated)
            sessionMode = .wasmRunning
            let runtime = wasmRuntime()

            // Chunk boundaries can split multibyte UTF-8 sequences; the
            // decoders buffer incomplete tails between chunks.
            let stdoutDecoder = StreamingUTF8Decoder()
            let stderrDecoder = StreamingUTF8Decoder()

            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = await runtime.run(
                    wasmURL: plan.wasmURL,
                    argv: plan.argv,
                    env: plan.env,
                    cwd: plan.cwd,
                    sandboxRoot: plan.sandboxRoot,
                    onStdout: { [weak self] data in
                        guard let self else { return }
                        let s = stdoutDecoder.decode(data)
                        if !s.isEmpty {
                            self.onOutput?(self.normalizeNewlinesKeepingCR(s))
                        }
                    },
                    onStderr: { [weak self] data in
                        guard let self else { return }
                        let s = stderrDecoder.decode(data)
                        if !s.isEmpty {
                            self.onOutput?(self.normalizeNewlinesKeepingCR(s))
                        }
                    }
                )

                // Flush any dangling partial sequence (as U+FFFD)
                let tail = stdoutDecoder.flush() + stderrDecoder.flush()
                if !tail.isEmpty {
                    self.onOutput?(self.normalizeNewlinesKeepingCR(tail))
                }

                self.lastCommandSucceeded = (code == 0)
                self.scriptCommandExitCode = code
                self.sessionMode = .localShell
                // Discard any half-typed cooked-mode line so the next wasm
                // run doesn't see stale buffer contents.
                self.wasmCookedBuffer.removeAll(keepingCapacity: false)
                if self.isRunning {
                    self.onTitleChange?(self.formatPathForTitle(self.sessionCurrentDirectory))
                    self.displayPrompt()
                }
            }
        }
    }

    /// Pure preparation: parses argv, resolves the `.wasm` path, builds the
    /// environment. No session-state mutation, no UI side effects. Shared
    /// between the interactive (`handleWasmCommand`) and pipeline
    /// (`streamWasmCommand`) entry points so the two paths can't drift.
    func prepareWasmLaunch(_ command: String) -> WasmPrepResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased() == "wasm" {
            return .usage("wasm: usage: wasm <file.wasm> [args...]   (or: wasm test)\n")
        }

        let rawParts = Self.splitArgv(trimmed)

        // Strip leading shell-style `NAME=value` assignments. Two sources:
        //  - User typed `FOO=bar wasm tool.wasm` at the prompt.
        //  - The pipeline renderer (`renderExternalPipelineSegment`) inlines
        //    the inherited shell environment as `NAME=value` prefix tokens —
        //    no `withTemporaryChildProcessEnvironment` runs for pipeline
        //    stages, so this is the *only* path that gets the env to wasm.
        // We collect them here and apply to the wasm env below.
        let (inlineAssignments, afterAssignments) = Self.splitLeadingAssignments(rawParts)

        let parts: [String]
        if afterAssignments.first?.lowercased() == "wasm" {
            parts = Array(afterAssignments.dropFirst())
        } else {
            parts = afterAssignments
        }

        // POSIX tilde expansion happens at the shell layer, before exec.
        // WASM clients (Rust std, Go's wasip1, …) treat `~` as a literal
        // path char. We expand against the *virtual* HOME (`/`) so the
        // post-expansion path stays inside the WASM sandbox view; any
        // wasi-libc / Go re-anchoring via PWD + preopen-strip then lands
        // at the right URL inside the broker.
        let userArgv: [String] = parts.map { arg -> String in
            if arg == "~" { return "/" }
            if arg.hasPrefix("~/") {
                return "/" + arg.dropFirst(2)
            }
            return arg
        }

        guard let firstArg = userArgv.first else {
            return .empty
        }

        // `wasm test` runs the in-app self-test (path sandbox + runtime
        // smoke) and prints results to the terminal. Lets users (and CI) do
        // end-to-end coverage without an XCTest target.
        if firstArg.lowercased() == "test" {
            return .selfTest
        }

        // Resolve the .wasm path: relative to cwd, then $HOME/bin, then
        // bundled demo. Avoids requiring users to type full paths to the
        // shipped demo binary.
        let wasmURL: URL
        do {
            wasmURL = try resolveWasmPath(firstArg)
        } catch {
            return .error("\(firstArg): \(error.localizedDescription)")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cwd = URL(fileURLWithPath: sessionCurrentDirectory, isDirectory: true)

        // CRITICAL: HOME and PWD must be *virtual* sandbox paths, not the
        // real device paths. WASI clients differ in how they handle paths:
        // wasi-libc (Rust) passes relative argv through the `.` preopen, but
        // Go's wasip1 always converts to absolute by joining $PWD before
        // doing preopen prefix-matching. If $PWD contained the real device
        // path, Go would emit a `path_open` whose path is the full device
        // path with a leading slash stripped — which the broker then
        // doubles when it resolves relative to the sandbox root. Exposing
        // virtual paths keeps both layouts inside the sandbox.
        let docsPath = docs.path
        let virtualCwd: String
        if cwd.path == docsPath {
            virtualCwd = "/"
        } else if cwd.path.hasPrefix(docsPath + "/") {
            virtualCwd = String(cwd.path.dropFirst(docsPath.count))
        } else {
            // CWD is outside the sandbox (shouldn't happen on iOS) — clamp
            // to root rather than leaking a host path.
            virtualCwd = "/"
        }
        // Start the env minimal. We deliberately do NOT copy
        // `ProcessInfo.processInfo.environment` wholesale: iOS apps inherit
        // a slew of host-side vars (CFFIXED_USER_HOME, TMPDIR, HOME=app
        // container, …) that name real device paths. The WASI brokers
        // resolve any leading `/` against the sandbox root, so leaking those
        // paths into wasm makes the runtime compute non-existent locations
        // (e.g. `dirs::cache_dir()` -> `$HOME/Library/Caches/...` blowing up
        // with EIO because the host path can't be opened through the
        // sandbox). The shell's *exported* env reaches wasm via the inline
        // `NAME=value` prefix the interpreter renders into the command for
        // pipeline / redirect / explicit-assignment paths; environ doesn't
        // need to be in the picture for that.
        var env: [String: String] = [:]
        // Inherit PATH only — useful for ported tooling that consults it,
        // and unlike HOME/TMPDIR it isn't a sandbox-escaping path.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            env["PATH"] = path
        }
        // Exported shell variables (interactive launches don't get the
        // inline-assignment rendering the pipeline path does). Sandbox
        // overrides below still win for path-bearing names.
        for (name, value) in sharedShellEnvironment.snapshotChildProcessEnvironment() {
            env[name] = value
        }
        // Apply inline assignments (user-typed `FOO=bar tool.wasm` and the
        // shell's exported env inlined by the pipeline / redirect renderers).
        for (name, value) in inlineAssignments {
            env[name] = value
        }
        // Virtual sandbox overrides — applied LAST so they always win. Even
        // if the shell exported HOME=/some/host/path, the wasm view of HOME
        // must stay sandbox-rooted (`/`) to keep WASI path resolution inside
        // the broker's allowed root. COLUMNS/LINES likewise need to reflect
        // the *current* PTY size, not whatever was inherited.
        env["HOME"] = "/"
        env["PWD"]  = virtualCwd
        env["COLUMNS"] = String(Int(pty.windowSize.cols))
        env["LINES"]   = String(Int(pty.windowSize.rows))

        let runtimeArgv = [wasmURL.lastPathComponent] + userArgv.dropFirst()
        return .ready(WasmLaunchPlan(
            wasmURL: wasmURL,
            argv: runtimeArgv,
            env: env,
            cwd: cwd,
            sandboxRoot: docs
        ))
    }

    /// Pipeline entry point: run a WASM command as a streaming stage with
    /// stdout going to the pipeline's `outputSink` (raw bytes, no CRLF
    /// translation), stderr to the terminal output sink, and stdin pumped
    /// from `inputProvider`. Mirrors the shape of `streamExternalCommand` so
    /// the shell interpreter can treat `.wasm` like any other pipeline stage.
    nonisolated func streamWasmCommand(
        _ command: String,
        inputProvider: (@Sendable () -> Data?)?,
        outputSink: @escaping @Sendable (Data) -> Bool
    ) -> Int32 {
        guard !scriptCancellationToken.isCancelled else { return 130 }

        // Hop to MainActor to prepare; wait synchronously. The semaphore +
        // captured-var pattern matches `bridgeToMainActor` elsewhere in the
        // file, so Swift 6 strict-concurrency treats this the same way.
        let prepSem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var prep: WasmPrepResult = .empty
        Task { @MainActor [weak self] in
            prep = self?.prepareWasmLaunch(command) ?? .empty
            prepSem.signal()
        }
        prepSem.wait()

        let terminalSink = self.outputSink

        switch prep {
        case .empty:
            return 0
        case .usage(let msg):
            terminalSink.emitString(msg)
            return 1
        case .error(let msg):
            terminalSink.emitString("wasm: \(msg)\n")
            return 1
        case .selfTest:
            // `wasm test` is interactive-only — it prints results to the
            // terminal and triggers the integration runner. Refuse rather
            // than silently producing nothing for the pipeline.
            terminalSink.emitString("wasm: 'wasm test' is not supported in pipelines\n")
            return 1
        case .ready(let plan):
            return runWasmStreaming(plan: plan,
                                    inputProvider: inputProvider,
                                    outputSink: outputSink)
        }
    }

    /// Synchronous bridge from the commandQueue thread to the @MainActor
    /// async `WasmRuntime.run`. The closure args run on MainActor and route
    /// stdout to the pipeline sink (raw) and stderr to the terminal sink
    /// (matches `streamExternalCommand`'s stderr handling for ios_system).
    nonisolated private func runWasmStreaming(
        plan: WasmLaunchPlan,
        inputProvider: (@Sendable () -> Data?)?,
        outputSink: @escaping @Sendable (Data) -> Bool
    ) -> Int32 {
        let doneSem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var exitCode: Int32 = 1
        nonisolated(unsafe) var wasCancelled = false
        let cancellationToken = scriptCancellationToken
        let terminalSink = self.outputSink
        // Cross-thread flag: onStdout (MainActor) writes; the outer loop on
        // commandQueue reads at the end. UnfairLock keeps the access race-free.
        let sinkClosedLock = UnfairLock()
        nonisolated(unsafe) var sinkClosed = false

        Task { @MainActor [weak self] in
            guard let self else {
                doneSem.signal()
                return
            }
            let runtime = self.wasmRuntime()
            // Don't touch sessionMode here. Pipeline stages run while the
            // outer script keeps the session in `.scriptRunning`; flipping
            // to `.wasmRunning` would mis-route keystrokes through
            // `forwardStdinToWasm` (the interactive solo path) instead of
            // through the pipeline's `inputProvider`, and the post-run reset
            // to `.localShell` would prematurely end the script.

            // Stdin pump. Polls runtime.current?.id each iteration: until the
            // runtime publishes the process, writes no-op (per
            // WasmRuntime.write's id-guard). In practice the runtime sets
            // `current` before the first inputProvider() chunk arrives.
            let stdinTask: Task<Void, Never>?
            if let inputProvider {
                stdinTask = Task.detached(priority: .userInitiated) { [weak runtime] in
                    while !cancellationToken.isCancelled,
                          let chunk = inputProvider(),
                          !chunk.isEmpty {
                        guard let runtime else { return }
                        await MainActor.run {
                            if let pid = runtime.current?.id {
                                runtime.write(stdin: chunk, processID: pid)
                            }
                        }
                    }
                }
            } else {
                stdinTask = nil
            }

            let code = await runtime.run(
                wasmURL: plan.wasmURL,
                argv: plan.argv,
                env: plan.env,
                cwd: plan.cwd,
                sandboxRoot: plan.sandboxRoot,
                onStdout: { data in
                    // Raw bytes to the pipeline. No `normalizeLineEndings` —
                    // that's only correct when output lands on the terminal
                    // display, not when piped or redirected.
                    let downstreamAlive = sinkClosedLock.withLock { () -> Bool in
                        if sinkClosed { return false }
                        if !outputSink(data) {
                            sinkClosed = true
                            return false
                        }
                        return true
                    }
                    if !downstreamAlive, let pid = runtime.current?.id {
                        // SIGPIPE-equivalent: downstream is gone, no point
                        // continuing the WASM process.
                        runtime.cancel(processID: pid)
                    }
                },
                onStderr: { data in
                    // Match ios_system streaming behaviour: stderr goes
                    // directly to the terminal output sink (raw bytes).
                    terminalSink.emit(data)
                }
            )

            stdinTask?.cancel()
            exitCode = code
            doneSem.signal()
        }

        // Wait for completion, polling for cancellation just like
        // bridgeToMainActor. Cancel via runtime.cancel rather than interrupt()
        // so we don't tear down the entire shell.
        while doneSem.wait(timeout: .now() + 0.1) != .success {
            if cancellationToken.isCancelled && !wasCancelled {
                wasCancelled = true
                Task { @MainActor [weak self] in
                    if let rt = self?.activeWasmRuntime, let pid = rt.current?.id {
                        rt.cancel(processID: pid)
                    }
                }
            }
        }

        if wasCancelled { return 130 }
        let closed = sinkClosedLock.withLock { sinkClosed }
        if closed { return 141 } // 128 + SIGPIPE(13)
        return exitCode
    }

    /// Forwards a stdin chunk to the running WASM process.
    func forwardStdinToWasm(_ data: Data) {
        guard case .wasmRunning = sessionMode else { return }
        guard let runtime = activeWasmRuntime, let proc = runtime.current else { return }
        runtime.write(stdin: data, processID: proc.id)
    }

    /// Cooked-mode TTY emulation for wasm stdin.
    ///
    /// Real PTYs sit between the kernel and the program and handle:
    ///   - ECHO:  typed bytes echo back to the display so the user sees them
    ///   - ICANON: input is line-buffered, only delivered on Enter
    ///   - ICRNL: Enter (carriage return, 0x0d) is translated to newline (0x0a)
    ///   - ERASE: backspace removes the previous character + redraws
    ///
    /// Without these the user appears unable to type: keystrokes invisible
    /// (no echo), and Enter doesn't terminate reads like `bufio.NewReader.
    /// ReadString('\n')` because the terminal byte is \r, not \n. rclone's
    /// interactive config uses exactly that read pattern.
    ///
    /// We buffer one line in `wasmCookedBuffer` and flush + LF to the wasm
    /// process on Enter. Backspace consumes from the buffer in-shell and is
    /// not forwarded. Unprintable control bytes (other than Enter / BS) are
    /// dropped silently — same as a Linux terminal in cooked mode.
    func handleCookedModeWasmInput(_ data: Data) {
        for byte in data {
            switch byte {
            case 0x0d, 0x0a:
                // Enter — finish the line, echo CRLF, forward buffer + LF.
                onOutput?("\r\n")
                wasmCookedBuffer.append(0x0a)
                let payload = Data(wasmCookedBuffer)
                wasmCookedBuffer.removeAll(keepingCapacity: true)
                forwardStdinToWasm(payload)
            case 0x7f, 0x08:
                // Backspace / DEL — erase one byte from the buffer + display.
                if !wasmCookedBuffer.isEmpty {
                    wasmCookedBuffer.removeLast()
                    onOutput?("\u{08} \u{08}")
                }
            case 0x04:
                // Ctrl-D — EOF if line is empty (POSIX VEOF), else ignored.
                // Forwarding an empty stdin chunk wakes the wasm read with
                // zero bytes; we additionally close the stdin queue so any
                // future reads return EOF immediately.
                if wasmCookedBuffer.isEmpty,
                   let runtime = activeWasmRuntime, let proc = runtime.current {
                    runtime.write(stdin: Data(), processID: proc.id)
                    _ = proc
                }
            default:
                // Echo printable bytes (>=0x20) plus tab (0x09). Drop other
                // control bytes — matches Linux cooked-mode behaviour for
                // unrecognised control chars.
                if byte >= 0x20 || byte == 0x09 {
                    wasmCookedBuffer.append(byte)
                    if let s = String(data: Data([byte]), encoding: .utf8) {
                        onOutput?(s)
                    }
                }
            }
        }
    }

    /// Cancels the running WASM process. Wired up by interrupt() when
    /// `sessionMode == .wasmRunning`.
    func cancelRunningWasm() {
        guard case .wasmRunning = sessionMode else { return }
        guard let runtime = activeWasmRuntime, let proc = runtime.current else { return }
        runtime.cancel(processID: proc.id)
    }

    // MARK: - Self-test

    private func runWasmSelfTest() {
        onOutput?(normalizeLineEndings("wasm self-test: path sandbox\n"))
        let pathResults = WasmPathSandboxSelfTest.run()
        var passed = 0
        for r in pathResults {
            let mark = r.passed ? "ok" : "FAIL"
            onOutput?(normalizeLineEndings("  [\(mark)] \(r.name) — \(r.message)\n"))
            if r.passed { passed += 1 }
        }
        onOutput?(normalizeLineEndings("\nwasm self-test: runtime smoke\n"))

        // The demo binary is build-and-test-locally — not bundled, not in
        // git. Look in $HOME/bin/wasm-demo.wasm first (the conventional
        // place users drop a personal build via Files app), then the cwd
        // as a fallback.
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidates = [
            docs.appendingPathComponent("bin/wasm-demo.wasm"),
            URL(fileURLWithPath: sessionCurrentDirectory)
                .appendingPathComponent("wasm-demo.wasm"),
        ]
        guard let demoURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            onOutput?(normalizeLineEndings(
                "  [skip] wasm-demo.wasm not found — build with " +
                "tests/wasm-demo/build.sh and drop dist/wasm-demo.wasm into " +
                "$HOME/bin/ or your cwd\n"
            ))
            lastCommandSucceeded = pathResults.allSatisfy { $0.passed }
            scriptCommandExitCode = lastCommandSucceeded ? 0 : 1
            sessionMode = .localShell
            displayPrompt()
            return
        }

        // Hand off to the integration runner (runs the demo end-to-end).
        let runtime = wasmRuntime()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let runner = WasmIntegrationRunner(session: self, demoURL: demoURL, runtime: runtime)
            let allPassed = await runner.runAll()
            self.lastCommandSucceeded = allPassed && pathResults.allSatisfy { $0.passed }
            self.scriptCommandExitCode = self.lastCommandSucceeded ? 0 : 1
            self.sessionMode = .localShell
            self.displayPrompt()
        }
    }

    // MARK: - Helpers

    /// Per-session runtime, lazy. Each tab keeps its own WKWebView so that
    /// `.wasm` invocations in different tabs are fully independent.
    private func wasmRuntime() -> WasmRuntime {
        if let r = activeWasmRuntime { return r }
        let r = WasmRuntime()
        WasmRuntimeRegistry.shared.set(r, for: ObjectIdentifier(self))
        return r
    }

    var activeWasmRuntime: WasmRuntime? {
        WasmRuntimeRegistry.shared.get(for: ObjectIdentifier(self))
    }

    private func resolveWasmPath(_ raw: String) throws -> URL {
        let fm = FileManager.default
        let cwd = sessionCurrentDirectory

        // Absolute path
        if raw.hasPrefix("/") {
            let url = URL(fileURLWithPath: raw)
            guard fm.fileExists(atPath: url.path) else {
                throw NSError(domain: "wasm", code: 2, userInfo: [NSLocalizedDescriptionKey: "no such file"])
            }
            return url
        }
        // Relative to cwd
        let cwdCandidate = URL(fileURLWithPath: cwd).appendingPathComponent(raw)
        if fm.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }
        // $HOME/bin/<raw>
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let binCandidate = docs.appendingPathComponent("bin").appendingPathComponent(raw)
            if fm.fileExists(atPath: binCandidate.path) {
                return binCandidate
            }
        }
        // Bundled demo: try Wasm/demo/<raw> in the app bundle (no .wasm
        // extension required).
        let basename = raw.hasSuffix(".wasm") ? String(raw.dropLast(5)) : raw
        if let demo = Bundle.main.url(forResource: basename, withExtension: "wasm", subdirectory: "Wasm/demo")
            ?? Bundle.main.url(forResource: basename, withExtension: "wasm") {
            return demo
        }
        throw NSError(domain: "wasm", code: 2, userInfo: [NSLocalizedDescriptionKey: "no such file"])
    }

    /// Classification of a raw command line for wasm dispatch. Used by the
    /// input dispatcher to recognise `FOO=bar wasm tool.wasm`-style commands
    /// where the literal first token isn't `wasm` / `*.wasm` but a leading
    /// assignment prefix has shifted it later.
    enum WasmDispatchKind: Sendable {
        case none
        case keyword       // first non-assignment token is `wasm`
        case bareDotWasm   // first non-assignment token ends in `.wasm`
    }

    /// Decide whether `command` is a wasm invocation, looking past any
    /// leading `NAME=value` assignment prefix. Shared with the input
    /// dispatcher (`LocalShellSession+Input.swift`) so both layers agree on
    /// what counts as a wasm command.
    static func wasmInvocationKind(in command: String) -> WasmDispatchKind {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = splitArgv(trimmed)
        let (_, rest) = splitLeadingAssignments(parts)
        guard let first = rest.first?.lowercased() else { return .none }
        if first == "wasm" { return .keyword }
        if first.hasSuffix(".wasm") { return .bareDotWasm }
        return .none
    }

    /// Strip leading shell-style `NAME=value` assignments from a tokenised
    /// command. POSIX rules: the name is `[A-Za-z_][A-Za-z0-9_]*` and must
    /// appear before any non-assignment word. The first token that fails the
    /// name check terminates the assignment prefix — everything after that is
    /// argv. `FOO=` (empty value) is valid; `2FOO=bar` is not.
    static func splitLeadingAssignments(_ tokens: [String]) -> (assignments: [(String, String)], rest: [String]) {
        var assignments: [(String, String)] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard let eqIdx = token.firstIndex(of: "=") else { break }
            let name = String(token[..<eqIdx])
            guard isValidAssignmentName(name) else { break }
            let value = String(token[token.index(after: eqIdx)...])
            assignments.append((name, value))
            i += 1
        }
        return (assignments, Array(tokens[i...]))
    }

    private static func isValidAssignmentName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        let isAlphaOrUnderscore: (Unicode.Scalar) -> Bool = { c in
            (c.value >= 0x41 && c.value <= 0x5A) // A-Z
            || (c.value >= 0x61 && c.value <= 0x7A) // a-z
            || c == "_"
        }
        let isAlnumOrUnderscore: (Unicode.Scalar) -> Bool = { c in
            isAlphaOrUnderscore(c) || (c.value >= 0x30 && c.value <= 0x39) // 0-9
        }
        guard isAlphaOrUnderscore(first) else { return false }
        return s.unicodeScalars.dropFirst().allSatisfy(isAlnumOrUnderscore)
    }

    /// Quote-aware argv splitter. The upstream input dispatch hands us the
    /// raw command line as a single String (see `handleWasmCommand(_:)`
    /// callers in LocalShellSession+Input.swift), so any quotes the user
    /// typed are still embedded. We need to split on unquoted whitespace
    /// while collapsing `'...'` and `"..."` into single tokens — otherwise
    /// `wasm outside.wasm --location "Boston, MA, US"` lands as
    /// argv = [outside.wasm, --location, "Boston,, MA,, US"] and clap can't
    /// match the value.
    ///
    /// Subset of POSIX:
    ///   - single quotes: literal, no escapes inside (incl. backslashes)
    ///   - double quotes: literal except `\\`, `\"`, `\\`-newline join
    ///   - `\` outside quotes: escapes the next char (preserves it literally)
    ///   - whitespace between tokens is a separator
    /// Unterminated quotes flush whatever was accumulated so the user at
    /// least sees a partial argv rather than nothing.
    static func splitArgv(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var i = s.startIndex

        while i < s.endIndex {
            let c = s[i]
            if inSingle {
                if c == "'" {
                    inSingle = false
                } else {
                    current.append(c)
                }
            } else if inDouble {
                if c == "\\" {
                    let next = s.index(after: i)
                    if next < s.endIndex {
                        let nc = s[next]
                        // In double quotes, backslash only escapes a handful
                        // of chars; otherwise it's literal.
                        if nc == "\"" || nc == "\\" || nc == "$" || nc == "`" {
                            current.append(nc)
                            i = next
                        } else {
                            current.append(c)
                        }
                    } else {
                        current.append(c)
                    }
                } else if c == "\"" {
                    inDouble = false
                } else {
                    current.append(c)
                }
            } else if c == "'" {
                inSingle = true
            } else if c == "\"" {
                inDouble = true
            } else if c == "\\" {
                let next = s.index(after: i)
                if next < s.endIndex {
                    current.append(s[next])
                    i = next
                }
                // trailing backslash at EOL: silently dropped
            } else if c.isWhitespace {
                if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
            } else {
                current.append(c)
            }
            i = s.index(after: i)
        }

        if !current.isEmpty {
            out.append(current)
        }
        return out
    }
}

#endif // !targetEnvironment(macCatalyst)
