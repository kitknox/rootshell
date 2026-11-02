// LocalShellSession is only used on iOS/visionOS (Mac Catalyst uses CatalystLocalShellSession)
#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog
import Citadel

/// Local shell session that executes commands using ios_system
/// Provides terminal I/O through a PTY pair
final class LocalShellSession: TerminalSession, EmbeddedConnectionConfigProviding {
    let pty: TerminalPTY

    private(set) var isRunning: Bool = false
    /// Set while start() waits on bookmark restoration; stop() clears it so a
    /// tab closed during the wait never starts.
    private var isStartPending = false
    var shellTask: Task<Void, Never>?
    var imgcatTask: Task<Void, Never>?
    var whatIsMyIPTask: Task<Void, Never>?
    var vpnTask: Task<Void, Never>?
    // Set once in init and never mutated, safe to access from any thread
    nonisolated(unsafe) var sessionID: UUID

    /// Terminal UUID for credential persistence (enables Mosh session resume)
    /// Set by TerminalView to allow embedded sessions to save credentials with the right terminal ID
    var terminalId: UUID?

    /// Theme resolution context for native local-shell tools hosted in this terminal.
    var containingTabId: UUID?
    var windowId: String?

    /// Whether to show the welcome banner on start. Set to false for restored sessions.
    var showWelcomeBanner: Bool = true

    /// Whether to suppress the initial prompt on restore. When true, the scrollback
    /// already contains the prompt from before backgrounding, so we skip displaying a new one.
    /// Only meaningful when `showWelcomeBanner` is false (restored sessions).
    var suppressPromptOnRestore: Bool = false

    /// Forwards approval prompts from embedded SSH-style sessions back to the owning terminal view.
    var onAgentApprovalRequired: (@MainActor @Sendable (SSHAgentApprovalRequest) -> Void)?

    /// Forwards keyboard-interactive (RFC 4256) prompts from embedded SSH-style
    /// sessions (and the rf browser) to the owning terminal view, which presents
    /// the shared SwiftUI prompt sheet. Returns one response per prompt, or nil
    /// to cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    // Track currently running command for interruption
    // These are protected by pidLock and accessed from multiple threads
    nonisolated(unsafe) var currentPid: pid_t?
    nonisolated let pidLock = UnfairLock()
    nonisolated(unsafe) var activeScriptCommandHandles: [OpaquePointer] = []

    // Input mode for routing user input
    enum InputMode: Sendable {
        case lineEditor      // Normal shell prompt - buffer in line editor
        case commandStdin    // Forward directly to running command's stdin
    }

    // Session mode for embedded SSH/SCP/SFTP/Mosh/Trzsz/Ping support
    enum SessionMode {
        case localShell                    // Normal local shell
        case sshSession                    // Embedded SSH session active
        case scpTransfer                   // SCP file transfer in progress
        case sftpSession                   // Interactive SFTP session active
        case moshSession                   // Embedded Mosh session active
        case trzszSession                  // Embedded Trzsz session active
        case pingRunning                   // Native ping command running
        case mtrRunning                    // Native mtr (rootshell traceroute) running
        case helixRunning                  // Native Helix editor running
        case rfBrowserRunning              // Native rf file browser running
        case gitRunning                    // Native git command running
        case crocRunning                   // Native croc file transfer running
        case passwordPrompt(SSHCommandParser.PartialSSHConfig)  // Waiting for SSH password input
        case scpPasswordPrompt(SCPParsedCommand, SSHCommandParser.PartialSSHConfig)  // Waiting for SCP password input
        case sftpPasswordPrompt(SSHCommandParser.PartialSSHConfig)  // Waiting for SFTP password input
        case moshPasswordPrompt(MoshCommandParser.PartialMoshConfig)  // Waiting for Mosh password input
        case trzszPasswordPrompt(TrzszCommandParser.PartialTrzszConfig)  // Waiting for Trzsz password input
        case sshCopyIDTransfer                                          // ssh-copy-id operation in progress
        case sshCopyIDPasswordPrompt(SSHCopyIDParsedCommand, SSHCommandParser.PartialSSHConfig)  // Waiting for ssh-copy-id password
        case gitPasswordPrompt(GitCommandParser.GitCommandConfig)  // Waiting for git --password input
        case aiCommitPrompt(request: GitEditorRequest, message: String)  // Waiting for commit/edit/abort after AI message
        case hostKeyPrompt(CheckedContinuation<HostKeyValidationResult, Never>)  // Waiting for host key response
        case savePasswordPrompt(host: String, port: Int, username: String, password: String)  // Prompt to save password after successful SSH
        case scriptRunning                 // Shell script interpreter active
        case scriptReadPrompt              // Script waiting for `read` builtin input
        case wasmRunning                   // .wasm binary executing in the WKWebView-hosted runtime
        case vpnRunning                    // Native vpn command running
    }

    // SSH/SCP/SFTP/Mosh/Trzsz mode state
    var sessionMode: SessionMode = .localShell {
        didSet { notifyLocalTaskStateIfNeeded() }
    }

    /// Whether the session is currently routing I/O to a remote connection.
    var isInRemoteMode: Bool {
        switch sessionMode {
        case .sshSession, .moshSession, .trzszSession, .sftpSession:
            return true
        default:
            return false
        }
    }
    /// Whether the local shell has an active long-running task that warrants background execution.
    /// Excludes SSH/Mosh/Trzsz which are tracked separately via onEmbeddedConnectionConfigChanged.
    var hasActiveLongRunningTask: Bool {
        switch sessionMode {
        case .helixRunning, .rfBrowserRunning, .sftpSession, .scpTransfer, .sshCopyIDTransfer, .pingRunning, .mtrRunning, .gitRunning, .crocRunning:
            return true
        case .localShell:
            // Only count full-screen commands (vim, less, nano) that use cursor control sequences.
            // NOT colorized output (ls --color) which only uses SGR sequences.
            return fullScreenLock.withLock { isFullScreenCommand }
        default:
            return false
        }
    }

    var embeddedSSHSession: TerminalSession? {
        didSet { updateAuthBannerCardForwarding() }
    }
    var embeddedSCPTransfer: SCPTransfer?
    var embeddedSFTPSession: SFTPSession?
    var embeddedMoshSession: MoshSession? {
        didSet { updateAuthBannerCardForwarding() }
    }
    var embeddedTrzszSession: TrzszSession? {
        didSet { updateAuthBannerCardForwarding() }
    }

    /// Relays the active embedded session's auth-banner card state through
    /// this session's own model, so the pane's single observation (of this
    /// LocalShellSession) sees banners from whichever embedded SSH/Mosh/Trzsz
    /// session is currently authenticating.
    let authBannerCardModel = SSHAuthBannerCardModel()
    private var authBannerCardForwardingTask: Task<Void, Never>?

    /// The embedded session whose card state this one currently mirrors.
    var currentAuthBannerProvider: SSHAuthBannerCardProviding? {
        (embeddedSSHSession as? SSHAuthBannerCardProviding)
            ?? (embeddedMoshSession as SSHAuthBannerCardProviding?)
            ?? (embeddedTrzszSession as SSHAuthBannerCardProviding?)
    }

    private func updateAuthBannerCardForwarding() {
        authBannerCardForwardingTask?.cancel()
        authBannerCardForwardingTask = nil
        guard let provider = currentAuthBannerProvider else {
            authBannerCardModel.clear()
            return
        }
        authBannerCardForwardingTask = Task { [weak self] in
            for await state in provider.authBannerCardStates() {
                guard let self, !Task.isCancelled else { return }
                self.authBannerCardModel.relay(state)
            }
        }
    }
    var embeddedConnectionStartTask: Task<Void, Never>?
    var embeddedConnectionStartTaskID: UUID?
    var activePingCommand: PingCommand?
    var activeMtrCommand: MtrCommand?
    var activeHelixCommand: HelixCommand?
    var activeRFCommand: RFCommand?
    var rfShellSuspended = false
    var activeGitCommand: GitCommand?
    var activeCrocCommand: CrocCommand?
    var crocPromptHandler: ((String) -> Void)?
    var passwordBuffer = ""

    // Track active embedded session configs (for session recovery)
    // These remain set while the embedded session is active, unlike lastAttempted* which are cleared on success
    var activeEmbeddedSSHConfig: SSHConfig?
    var activeEmbeddedMoshConfig: MoshConfig?
    var activeEmbeddedTrzszConfig: TrzszConfig?

    // Track shell working directory for session recovery
    // This is the CWD of the local shell before launching an embedded session
    var currentWorkingDirectory: String?

    // Save password prompt state
    var savePasswordResponseBuffer = ""
    var pendingPasswordToSave: (host: String, port: Int, username: String, password: String)?

    // SSH Copy ID state
    var embeddedSSHCopyID: SSHCopyID?
    var lastAttemptedSSHCopyIDCommand: SSHCopyIDParsedCommand?
    var lastAttemptedSSHCopyIDConfig: SSHConfig?

    // Track last attempted configs for auth failure password fallback
    var lastAttemptedSSHConfig: SSHConfig?
    var lastAttemptedSFTPConfig: SSHConfig?
    var lastAttemptedSCPCommand: SCPParsedCommand?
    var lastAttemptedSCPConfig: SSHConfig?
    var lastAttemptedMoshConfig: MoshConfig?
    var lastAttemptedTrzszConfig: TrzszConfig?

    // Inline animation state for embedded SSH progress
    var inlineSpinnerAnimator: InlineSpinnerAnimator?
    var inlineFailureAnimator: InlineFailureAnimator?

    // Tab completion state (consolidated into state structs)
    var sshCompletion = HostCompletionState()
    var sftpCompletion = HostCompletionState()
    var moshCompletion = HostCompletionState()
    var trzszCompletion = HostCompletionState()
    var sshCopyIDCompletion = HostCompletionState()
    var scpCompletion = SCPCompletionState()

    // General file/command tab completion state machine
    enum GeneralCompletionState {
        case idle
        case waitingForSecondTab(allMatches: [String], displayNames: [String], range: Range<Int>)
        case cycling(originalBuffer: String, allMatches: [String], range: Range<Int>, currentIndex: Int)
    }
    var generalCompletionState: GeneralCompletionState = .idle

    // Ghost text state (inline completion hint)
    var currentGhostText: String = ""

    // Stores the most recent killed text for Ctrl-Y yank support.
    var lineEditorYankBuffer: String = ""

    // These are protected by stdinLock and accessed from multiple threads
    nonisolated(unsafe) var inputMode: InputMode = .lineEditor
    nonisolated(unsafe) var commandStdinWriteFd: Int32 = -1
    /// Cooked-stdin mode: echo typed chars locally, send whole lines on Enter, close on Ctrl-D.
    /// Armed only for allow-listed stdin-consuming commands (bat, cat, grep, ...) with no file arg.
    /// Protected by stdinLock.
    nonisolated(unsafe) var cookedStdinActive: Bool = false
    nonisolated(unsafe) var cookedLineBuffer: Data = Data()
    nonisolated let stdinLock = UnfairLock()

    /// Type-ahead buffer: input received while a non-full-screen command is running.
    /// Replayed through processInput() when the command completes.
    var typeAheadBuffer = Data()

    // Nonisolated mirror of the stopped state (isRunning is MainActor),
    // lock-protected via CancellationToken for safe cross-thread access.
    // Cancelled at the top of stop(); read by queued commandQueue work so a
    // script queued behind teardown can't start against the dead session
    // (or un-cancel the token stop() just cancelled).
    nonisolated let stopFlag = CancellationToken()
    nonisolated var hasStopped: Bool { stopFlag.isCancelled }

    // Async command handle for ios_system_async
    // Protected by pidLock
    nonisolated(unsafe) var currentCommand: OpaquePointer? // ios_command_t*

    // Caches gitCommandNeedsInterception per command string — the check needs
    // a sync MainActor hop and interceptedAppCommand runs 3-4x per script
    // command. Cleared on each top-level submission. Protected by its lock.
    nonisolated(unsafe) var gitClassificationCache: [String: Bool] = [:]
    nonisolated let gitClassificationLock = UnfairLock()

    // Track whether a force-kill fallback timer is already pending (prevents double Ctrl-C stacking)
    // Protected by pidLock
    nonisolated(unsafe) var forceKillScheduled: Bool = false

    // Shell script interpreter support
    nonisolated let scriptCancellationToken = CancellationToken()
    var activeShellInterpreter: ShellInterpreter?
    var readLineContinuation: ((String?) -> Void)?
    var scriptReadBuffer: String = ""
    var scriptReadSilent: Bool = false

    /// Cooked-mode line buffer for wasm stdin. Accumulates typed bytes
    /// until Enter, mirroring a real PTY with ICANON + ECHO + ICRNL. Flushed
    /// to the wasm process as a single chunk ending in `\n`. Cleared on
    /// process exit. Unused when the wasm program has switched to raw mode
    /// via `rootshell_terminal_set_raw(1)`.
    var wasmCookedBuffer: [UInt8] = []

    /// Shared shell environment for the interactive session.
    /// Persists variables, functions, and traps across source/eval commands.
    /// Set once in init() alongside sessionID. Safe to access from any thread
    /// (ShellEnvironment is @unchecked Sendable with internal locking).
    nonisolated(unsafe) var sharedShellEnvironment: ShellEnvironment

    // Multi-line input buffer for incomplete compound commands (if/for/while/etc.)
    // When the user types `while [ 1 ]` and presses Enter, the parser detects
    // incomplete input and we show a `> ` continuation prompt.
    var multiLineInputBuffer: String?

    /// Completion callback for app commands running inside scripts.
    /// Set by bridgeToMainActor(), called when the command finishes (session returns to localShell).
    var scriptCommandCompletion: (() -> Void)?
    var scriptCommandExitCode: Int32?

    // Track interactive command detection (cursor control sequences in output)
    // Used to determine CTRL-C behavior: interactive programs handle it themselves
    // Protected by interactiveLock
    nonisolated(unsafe) var isCurrentCommandInteractive: Bool = false
    nonisolated let interactiveLock = UnfairLock()

    // Track full-screen command detection (non-SGR cursor control sequences)
    // Unlike isCurrentCommandInteractive (set by any ESC byte including colors),
    // this only triggers for genuine screen control (cursor movement, clear, etc.)
    // Used for location diary: vim/less/nano should keep app alive, but `ls --color` should not
    // Protected by fullScreenLock
    nonisolated(unsafe) var isFullScreenCommand: Bool = false
    nonisolated let fullScreenLock = UnfairLock()

    // Normalize LF -> CRLF for line-based output; disable once full-screen control sequences appear.
    // Protected by outputNormalizationLock
    nonisolated(unsafe) var shouldNormalizeOutput: Bool = true
    nonisolated let outputNormalizationLock = UnfairLock()

    // Per-shell queue for command execution
    // ios_system is now fully thread-safe with per-session state
    let commandQueue = DispatchQueue(label: "com.rootshell.localshell", qos: .userInitiated)

    // Output batching to reduce MainActor churn during high-volume commands
    private static let outputBatchMinMs = 8
    private static let outputBatchMaxMs = 32

    nonisolated let outputSink: OutputSink
    nonisolated let outputBatcher: OutputBatcher

    // Logger
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "localshell")

    // Callbacks
    // NOTE: These callbacks may be called from a background thread (batcher queue).
    // Callers must ensure thread-safe handling.
    var onOutput: (@Sendable (String) -> Void)? {
        didSet {
            outputSink.update(onOutput: onOutput, onOutputData: onOutputData)
        }
    }
    var onOutputData: (@Sendable (Data) -> Void)? {
        didSet {
            outputSink.update(onOutput: onOutput, onOutputData: onOutputData)
        }
    }
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onTerminalReset: (() -> Void)?

    /// One-shot: a shared file to open in $EDITOR right after the shell
    /// starts (set by TerminalSessionController from the tab's pending
    /// file-open handoff, see FileOpenCoordinator). Consumed in start().
    var startupFileToEdit: String?

    /// Called when the embedded session config changes (SSH/Mosh/Trzsz start or end).
    /// Passes the new ConnectionConfig when an embedded session starts, or nil when returning to local shell.
    /// Used to update TerminalView.connectionConfig so session counting picks up shell-launched sessions.
    var onEmbeddedConnectionConfigChanged: ((ConnectionConfig?) -> Void)?

    /// Called when an embedded trzsz session reaches `.running`. The parent
    /// terminal view uses this to apply the mode-restoration trailer
    /// (alt-screen / mouse capture / cursor key mode / bracketed paste / cursor
    /// shape) for resumed sessions, mirroring the top-level `.trzsz` path.
    var onEmbeddedTrzszReady: (@MainActor (TrzszSession) -> Void)?
    var onEmbeddedTrzszFreshSession: (@Sendable () -> Void)?
    var embeddedTrzszProtocolObserver: TerminalProtocolObserver?

    /// Called when an embedded trzsz session fails before reaching `.running`
    /// (auth failure, host-key failure, expired credentials, network error).
    /// The parent terminal view uses this to release the scrollback-restore
    /// gate it was holding open in anticipation of the resume trailer that
    /// will never arrive — so the failure UI / password prompt this session
    /// will emit shortly via `onOutput` actually reaches Ghostty instead of
    /// being buffered indefinitely.
    var onEmbeddedTrzszFailedBeforeRunning: (@MainActor () -> Void)?

    /// Called when the local shell's long-running task state changes (helix, sftp, scp, ping, interactive commands).
    /// Used by TerminalView to signal SessionTracker/LocationDiaryManager for background execution.
    var onLocalTaskActiveChanged: ((Bool) -> Void)?

    /// Last reported task-active state to avoid redundant callbacks
    private var lastReportedTaskActive: Bool = false

    /// Check if hasActiveLongRunningTask changed and fire callback if so
    func notifyLocalTaskStateIfNeeded() {
        let isActive = hasActiveLongRunningTask
        guard isActive != lastReportedTaskActive else { return }
        lastReportedTaskActive = isActive
        onLocalTaskActiveChanged?(isActive)
    }

    // Reconnection support - local shell does not support reconnection
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?
    var supportsAutoReconnect: Bool { false }

    // Connection metadata
    private(set) var connectionStartTime: Date?

    var connectionInfo: ConnectionInfo? {
        guard let startTime = connectionStartTime else { return nil }
        return .local(
            shell: "rootshell shell",
            workingDirectory: currentWorkingDirectory,
            connectedAt: startTime
        )
    }

    /// Whether an embedded SSH, SFTP, Mosh, or Trzsz session is currently active
    /// Used by keyboard handlers to determine if Ctrl-C should be forwarded
    /// rather than triggering local shell interrupt
    var hasActiveEmbeddedSession: Bool {
        if case .sshSession = sessionMode, embeddedSSHSession != nil {
            return true
        }
        if case .sftpSession = sessionMode, embeddedSFTPSession != nil {
            return true
        }
        if case .moshSession = sessionMode, embeddedMoshSession != nil {
            return true
        }
        if case .trzszSession = sessionMode, embeddedTrzszSession != nil {
            return true
        }
        return false
    }

    /// Returns the active embedded session's ConnectionConfig with shell context
    /// Used for session recovery - allows serializing shell-launched SSH/Mosh/Trzsz sessions
    var activeEmbeddedConnectionConfig: ConnectionConfig? {
        switch sessionMode {
        case .sshSession:
            guard embeddedSSHSession != nil, let config = activeEmbeddedSSHConfig else {
                return nil
            }
            return .shellLaunchedSSH(sshConfig: config, shellWorkingDirectory: currentWorkingDirectory)
        case .moshSession:
            guard embeddedMoshSession != nil, let config = activeEmbeddedMoshConfig else {
                return nil
            }
            return .shellLaunchedMosh(moshConfig: config, shellWorkingDirectory: currentWorkingDirectory)
        case .trzszSession:
            guard embeddedTrzszSession != nil, let config = activeEmbeddedTrzszConfig else {
                return nil
            }
            return .shellLaunchedTrzsz(trzszConfig: config, shellWorkingDirectory: currentWorkingDirectory)
        default:
            return nil
        }
    }

    // Line editing components
    let lineEditor = LineEditor()
    let historyManager = HistoryManager()
    let completionProvider = CompletionProvider()

    // Prompt state
    var lastCommandSucceeded: Bool = true

    /// Number of visible lines the current prompt occupies (info bar + input line).
    /// Used by transient prompt to know how many lines to erase/overwrite.
    var lastPromptLineCount: Int = 2

    // Prompt cache to avoid regenerating on every keystroke
    var promptCache = PromptCache()

    // Input parsing buffers
    var escapeBuffer = ""
    var hostKeyResponseBuffer = ""

    /// Returns the per-session working directory from ios_system's sessionParameters.
    /// This avoids reading the process-global FileManager CWD which can be
    /// overwritten by other sessions.
    var sessionCurrentDirectory: String {
        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)
        return (ios_getLogicalPWD(sessionPtr) as String?)
            ?? FileManager.default.currentDirectoryPath
    }

    /// Creates a new local shell session with the given PTY
    init(pty: TerminalPTY) {
        self.pty = pty
        let id = UUID()
        self.sessionID = id
        self.sharedShellEnvironment = ShellEnvironment(sessionID: id)
        let outputSink = OutputSink()
        self.outputSink = outputSink
        self.outputBatcher = OutputBatcher(
            minBatchIntervalMs: Self.outputBatchMinMs,
            maxBatchIntervalMs: Self.outputBatchMaxMs
        ) { [outputSink] data in
            // Called directly on batcher queue - NO MainActor crossing.
            // The onOutputData/onOutput callbacks must be thread-safe.
            outputSink.emit(data)
        }
    }

    /// Starts the local shell session
    func start() async throws {
        isStartPending = true
        await BookmarkedLocationsManager.shared.waitUntilSynced()
        guard !isRunning else { return }
        // Stopped during the wait: throw so callers skip follow-up work
        // (embedded SSH/Mosh/Trzsz launches).
        guard isStartPending else { throw CancellationError() }
        isStartPending = false

        Self.logger.info("Starting local shell session")

        // Setup ios_system session
        setupIOSSystemSession()

        isRunning = true
        connectionStartTime = Date()

        // Source ~/.rootshellrc (after env setup, before welcome banner)
        let rcFileHadActiveLines = executeRCFile()

        // Display welcome message and prompt (skip both for seamless restored sessions,
        // and skip banner entirely when user has a custom .rootshellrc)
        if showWelcomeBanner && !rcFileHadActiveLines {
            let cols = Int(pty.windowSize.cols)
            let banner = LocalShellBanner.render(columns: cols, theme: starshipTheme)
            onOutput?(normalizeLineEndings(banner))
            displayPrompt()
        } else if showWelcomeBanner {
            // User has a custom rc file — just show the prompt
            displayPrompt()
        } else if suppressPromptOnRestore {
            // Seamless restore: scrollback already contains the prior prompt.
            // Just update tab title/cwd without any terminal output.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentPath = self.sessionCurrentDirectory
                self.currentWorkingDirectory = currentPath
                self.onWorkingDirectoryChange?(currentPath)
                let formattedPath = self.formatPathForTitle(currentPath)
                self.onTitleChange?(formattedPath)
            }
        } else {
            // Restored but a command was running at termination time —
            // scrollback has no prompt, so display one now.
            displayPrompt()
        }

        Self.logger.info("Local shell session started successfully")

        // Session is ready immediately for local shells
        Self.logger.info("Local shell ready, firing onReady callback")
        onReady?()

        // Shared-file handoff: launch the editor on the imported file.
        // Resolved here (not at deposit time) so an `export EDITOR=...`
        // from ~/.rootshellrc — sourced above — is honored.
        if let fileToEdit = startupFileToEdit {
            startupFileToEdit = nil
            let editor: String
            if let envEditor = ios_getenv("EDITOR"),
               let editorStr = String(validatingCString: envEditor),
               !editorStr.isEmpty {
                editor = editorStr
            } else {
                editor = "hx"
            }
            let escapedFile = Self.posixShellEscapeForIOSSystem(fileToEdit)
            handleCommandSubmission("\(editor) \(escapedFile)")
        }
    }

    /// Stops the shell session gracefully
    func stop() {
        stop(preservingEmbeddedRoamSessions: false)
    }

    /// Stops the local shell while preserving embedded Mosh/Trzsz server-side
    /// sessions for a later app-restoration reattach.
    func stopForReconnect() {
        stop(preservingEmbeddedRoamSessions: true)
    }

    private func stop(preservingEmbeddedRoamSessions: Bool) {
        isStartPending = false
        guard isRunning else { return }

        Self.logger.info("Stopping local shell session")

        isRunning = false
        outputBatcher.flush()
        shellTask?.cancel()
        shellTask = nil
        imgcatTask?.cancel()
        imgcatTask = nil
        whatIsMyIPTask?.cancel()
        whatIsMyIPTask = nil
        vpnTask?.cancel()
        vpnTask = nil

        // Stop any embedded SSH session
        embeddedSSHSession?.stop()
        embeddedSSHSession = nil
        activeEmbeddedSSHConfig = nil

        // Stop any embedded Mosh session
        if embeddedMoshSession != nil {
            if preservingEmbeddedRoamSessions {
                embeddedMoshSession?.stopForReconnect()
            } else {
                embeddedMoshSession?.stop()
            }
            embeddedMoshSession = nil
            activeEmbeddedMoshConfig = nil
            NotificationCenter.default.post(name: .ghosttyEmbeddedMoshSessionDidChange, object: self)
        }

        // Stop any embedded Trzsz session
        if embeddedTrzszSession != nil {
            if preservingEmbeddedRoamSessions {
                embeddedTrzszSession?.stopForReconnect()
            } else {
                embeddedTrzszSession?.stop()
            }
            embeddedTrzszSession = nil
            activeEmbeddedTrzszConfig = nil
            NotificationCenter.default.post(name: .ghosttyEmbeddedTrzszSessionDidChange, object: self)
        }

        // Cancel any running ping command
        if activePingCommand != nil {
            activePingCommand?.cancel()
            activePingCommand = nil
        }

        // Cancel any running mtr command
        if activeMtrCommand != nil {
            activeMtrCommand?.cancel()
            activeMtrCommand = nil
        }

        // Cancel any running Helix editor
        if activeHelixCommand != nil {
            activeHelixCommand?.cancel()
            activeHelixCommand = nil
        }

        // Cancel any running rf file browser
        if activeRFCommand != nil {
            activeRFCommand?.cancel()
            activeRFCommand = nil
            rfShellSuspended = false
        }

        // Cancel any running git command
        if activeGitCommand != nil {
            activeGitCommand?.cancel()
            activeGitCommand = nil
        }

        sessionMode = .localShell

        // Stop any running animations
        inlineSpinnerAnimator?.stop()
        inlineSpinnerAnimator = nil
        inlineFailureAnimator?.stop()
        inlineFailureAnimator = nil

        // Mark stopped BEFORE cancelling: queued commandQueue work checks
        // this flag and bails instead of resetting the token below.
        stopFlag.cancel()

        // Cancel any running interpreter script so `sleep 10; ls` unwinds
        // instead of racing teardown — builtins, loops, and streaming stages
        // all poll this token.
        scriptCancellationToken.cancel()

        // Kill any running ios_system command to unblock commandQueue.
        // Without this, commandQueue.sync{} deadlocks when an interactive
        // command (vim, less, joe, etc.) is blocked waiting for user input.
        let cmdToKill: OpaquePointer? = pidLock.withLock { currentCommand }
        if let cmd = cmdToKill {
            ios_command_kill(cmd)
        }

        // Close stdin write end to ensure the command isn't blocked on stdin read.
        // runExternalCommand() checks commandStdinWriteFd under lock and skips
        // the close if already -1, so this won't cause a double-close.
        let stdinFdToClose = stdinLock.withLock {
            let fd = commandStdinWriteFd
            commandStdinWriteFd = -1
            return fd
        }
        if stdinFdToClose >= 0 {
            close(stdinFdToClose)
        }

        // Cancel background jobs before tearing down the session. Builtin
        // jobs observe their tokens; external job commands don't, so
        // force-kill every live streaming handle too (under pidLock — owners
        // remove their handle under the same lock before releasing it).
        sharedShellEnvironment.jobTable.cancelAll()
        pidLock.withLock {
            for handle in activeScriptCommandHandles {
                ios_command_kill(handle)
            }
        }

        // Finish teardown off the main actor: the queue drain (2s) plus the
        // handle drain (1.5s) would otherwise freeze the UI on a stubborn
        // tab. The strong capture keeps the session alive until teardown
        // completes; every member touched below is nonisolated.
        let session = self
        DispatchQueue.global(qos: .userInitiated).async {

            // Wait for runExternalCommand()/runScript() to finish cleanup.
            // After the kills above this completes quickly; the timeout is a
            // wedge safety net.
            let drainDone = DispatchSemaphore(value: 0)
            session.commandQueue.async { drainDone.signal() }
            let drainTimedOut = drainDone.wait(timeout: .now() + 2.0) == .timedOut
            if drainTimedOut {
                Self.logger.warning("commandQueue drain timed out during stop()")
            }

            // Bounded wait for killed streaming loops to unwind: they may
            // still be inside try_wait/wait/pipe cleanup against this
            // session. Normal exit after kill is <100ms; uncancellable
            // commands (rg/jq) may outlive the bound.
            let drainDeadline = Date().addingTimeInterval(1.5)
            while Date() < drainDeadline {
                let busy = session.pidLock.withLock {
                    !session.activeScriptCommandHandles.isEmpty || session.currentCommand != nil
                } || session.sharedShellEnvironment.jobTable.hasRunningJobs
                if !busy { break }
                Thread.sleep(forTimeInterval: 0.05)
            }

            let sessionPtr = IOSSystemSessionKey.key(for: session.sessionID)
            let stillBusy = drainTimedOut
                || session.pidLock.withLock {
                    !session.activeScriptCommandHandles.isEmpty || session.currentCommand != nil
                }
                || session.sharedShellEnvironment.jobTable.hasRunningJobs

            if stillBusy {
                // A survivor may still be using the session (a timed-out
                // queue can hold more queued work too) — leak both the C
                // session and the key rather than closing under a live
                // command.
                Self.logger.warning("stop(): work outlived teardown — leaking session")
            } else {
                // Clear tty before closing session to prevent ios_session_cleanup_params
                // from trying to fclose(stdin) when sp->tty was never changed from its
                // default value of stdin (e.g., if no command was ever run)
                ios_switchSession(sessionPtr)
                ios_settty(nil)

                ios_closeSession(sessionPtr)
                IOSSystemSessionKey.release(session.sessionID)
            }
        }

        // PTY will be closed in deinit
    }

    /// Interrupts the currently running command (Ctrl-C)
    ///
    /// Behavior depends on command type:
    /// - For interactive programs (joe, vim, ssh): Send 0x03 to stdin, let them handle it
    /// - For non-interactive programs (tail -f, sleep, curl): Graceful-then-forceful strategy:
    ///   1. Show ^C and send 0x03 to stdin immediately
    ///   2. ios_kill() for graceful shutdown (preserves ping statistics, etc.)
    ///   3. After 300ms, force-kill via ios_command_kill() if still running
    func interrupt() {
        Self.logger.debug("[Ctrl-C] interrupt() called")

        // Script interpreter: cancel via token, then fall through to kill current command.
        // Check activeShellInterpreter (not just sessionMode) because during a bridged
        // app command (ping, ssh, etc.), sessionMode changes to .pingRunning etc.
        // We need to cancel the token so the interpreter stops after the command returns.
        if activeShellInterpreter != nil {
            Self.logger.info("[Ctrl-C] Cancelling script interpreter")
            scriptCancellationToken.cancel()
            // Fall through to also kill the current app/ios_system command
        }

        // Script read prompt: cancel read and return to shell
        if case .scriptReadPrompt = sessionMode {
            Self.logger.info("[Ctrl-C] Cancelling script read prompt")
            readLineContinuation?(nil)
            readLineContinuation = nil
            scriptReadBuffer = ""
            scriptCancellationToken.cancel()
            // Don't return to .localShell here — let recoverFromScriptExecution handle it
            return
        }

        // Check for croc mode - cancel transfer
        if case .crocRunning = sessionMode {
            Self.logger.info("[Ctrl-C] Cancelling croc command")
            activeCrocCommand?.cancel()
            return
        }

        // Check for ping mode - cancel and print summary
        if case .pingRunning = sessionMode {
            Self.logger.info("[Ctrl-C] Cancelling ping command")
            activePingCommand?.cancel()
            return
        }

        // WASM running: tell the runtime to abort. It'll fire onExit which
        // restores .localShell and the prompt.
        if case .wasmRunning = sessionMode {
            Self.logger.info("[Ctrl-C] Cancelling WASM command")
            cancelRunningWasm()
            return
        }

        // Check for mtr mode - forward Ctrl-C as input (mtr handles quit internally)
        if case .mtrRunning = sessionMode {
            Self.logger.info("[Ctrl-C] Forwarding to mtr as input")
            activeMtrCommand?.sendInput(Data([0x03]))
            return
        }

        // Check for Helix mode - forward Ctrl-C as input (Helix handles it internally)
        if case .helixRunning = sessionMode {
            Self.logger.debug("[Ctrl-C] Forwarding to Helix as input")
            activeHelixCommand?.sendInput(Data([0x03]))
            return
        }

        // Check for rf file browser mode - forward Ctrl-C as input (rf handles quit internally)
        if case .rfBrowserRunning = sessionMode {
            Self.logger.debug("[Ctrl-C] Forwarding to rf as input")
            activeRFCommand?.sendInput(Data([0x03]))
            return
        }

        // Check for git mode - cancel the running git command
        if case .gitRunning = sessionMode {
            Self.logger.info("[Ctrl-C] Cancelling git command")
            activeGitCommand?.cancel()
            return
        }

        // Check for whatismyip task - cancel the async STUN/ASN lookup
        if let task = whatIsMyIPTask {
            Self.logger.info("[Ctrl-C] Cancelling whatismyip command")
            task.cancel()
            whatIsMyIPTask = nil
            onOutput?("^C\r\n")
            displayPrompt()
            return
        }

        #if !CHINA_BUILD
        if case .vpnRunning = sessionMode {
            Self.logger.info("[Ctrl-C] Cancelling vpn command")
            cancelVPNCommand()
            return
        }
        #endif

        // Check for SCP transfer mode FIRST - handle synchronously on MainActor
        // This must happen before the local shell handler runs
        if case .scpTransfer = sessionMode {
            Self.logger.info("[Ctrl-C] Cancelling SCP transfer")

            // Cancel the transfer - clears callbacks and closes connections
            embeddedSCPTransfer?.cancel()
            embeddedSCPTransfer = nil

            // Reset session state
            sessionMode = .localShell

            // Clean up spinner and show prompt
            let cleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
            inlineSpinnerAnimator?.stop()
            inlineSpinnerAnimator = nil
            onOutput?(cleanup)
            onOutput?("^C\r\n")
            displayPrompt()
            return
        }

        // Check for prompt modes - cancel and return to local shell
        switch sessionMode {
        case .passwordPrompt, .scpPasswordPrompt, .sftpPasswordPrompt,
             .moshPasswordPrompt, .trzszPasswordPrompt, .sshCopyIDPasswordPrompt,
             .gitPasswordPrompt:
            Self.logger.info("[Ctrl-C] Cancelling password prompt")
            passwordBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            displayPrompt()
            return

        case .hostKeyPrompt(let continuation):
            Self.logger.info("[Ctrl-C] Cancelling host key prompt")
            hostKeyResponseBuffer = ""
            sessionMode = .localShell
            onOutput?(normalizeLineEndings("^C\n"))
            continuation.resume(returning: .reject)
            displayPrompt()
            return

        case .savePasswordPrompt:
            Self.logger.info("[Ctrl-C] Cancelling save password prompt")
            savePasswordResponseBuffer = ""
            sessionMode = .localShell
            pendingPasswordToSave = nil
            onOutput?(normalizeLineEndings("^C\n"))
            displayPrompt()
            return

        case .aiCommitPrompt(let request, _):
            Self.logger.info("[Ctrl-C] Cancelling AI commit prompt")
            sessionMode = .localShell
            try? FileManager.default.removeItem(atPath: request.filePath)
            onOutput?(normalizeLineEndings("^C\n"))
            displayPrompt()
            return

        default:
            break
        }

        // Signal imgtext to stop processing (no-op if imgtext isn't running)
        imgtextCancelFlag = true

        // Clear type-ahead buffer — user is cancelling, not expecting replay
        typeAheadBuffer.removeAll()

        // Don't queue on commandQueue - it's blocked by ios_system_async wait!
        // Handle interruption directly on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Get current command state
            let (cmd, pid, scriptHandles) = self.pidLock.withLock {
                (self.currentCommand, self.currentPid, self.activeScriptCommandHandles)
            }

            // Capture Sendable values for logging
            let pidStr = pid != nil ? String(pid!) : "nil"
            let hasCmd = cmd != nil

            Task { @MainActor in
                let cmdStatus = hasCmd ? "present" : "nil"
                Self.logger.debug("[Ctrl-C] Current pid: \(pidStr), cmd handle: \(cmdStatus)")
            }

            guard pid != nil || cmd != nil || !scriptHandles.isEmpty else {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    Self.logger.debug("[Ctrl-C] No command running - resetting prompt")
                    // Show ^C and reset prompt (like bash)
                    self.onOutput?(self.normalizeLineEndings("^C\n"))
                    self.lineEditor.clear()
                    self.historyManager.stopNavigation()
                    self.generalCompletionState = .idle
                    self.multiLineInputBuffer = nil
                    self.displayPrompt()
                }
                return
            }

            // Check if command is interactive
            let isInteractive = self.interactiveLock.withLock { self.isCurrentCommandInteractive }

            // Get stdin write FD
            let writeFd = self.stdinLock.withLock { self.commandStdinWriteFd }

            // Handle based on command type
            let sessionPtr = IOSSystemSessionKey.key(for: self.sessionID)

            if isInteractive {
                // Interactive programs (joe, vim, ssh): Send 0x03 to stdin
                if writeFd >= 0 {
                    let ctrlC: [UInt8] = [0x03]
                    let written = Darwin.write(writeFd, ctrlC, 1)
                    Task { @MainActor in
                        if written > 0 {
                            Self.logger.debug("[Ctrl-C] Sent 0x03 to stdin pipe for interactive command")
                        } else {
                            Self.logger.warning("[Ctrl-C] Failed to write to stdin: errno=\(errno)")
                        }
                    }
                }
            } else {
                // Non-interactive programs (tail -f, sleep, curl, etc): graceful-then-forceful strategy
                // 1. Show ^C immediately for visual feedback
                // 2. Send 0x03 to stdin (belt-and-suspenders for commands that check stdin)
                // 3. ios_kill() for graceful shutdown (preserves ping statistics, etc.)
                // 4. After 300ms, force-kill if command is still running (unblocks blocked syscalls)

                Self.logger.debug("[Ctrl-C] Non-interactive command - graceful-then-forceful interrupt")

                // Show ^C immediately via thread-safe outputSink
                self.outputSink.emitString("^C\r\n")

                // Send 0x03 to stdin pipe (belt-and-suspenders)
                if writeFd >= 0 {
                    let ctrlC: [UInt8] = [0x03]
                    _ = Darwin.write(writeFd, ctrlC, 1)
                }

                // Close stdin write end to send EOF to commands blocked on stdin read.
                // Commands like sed/cat/wc with no file args block in read() on stdin;
                // closing the write end makes read() return 0 (EOF) for a clean exit
                // without needing ios_command_kill() which can crash mid-read commands.
                let stdinFdToClose = self.stdinLock.withLock {
                    let fd = self.commandStdinWriteFd
                    if fd >= 0 { self.commandStdinWriteFd = -1 }
                    return fd
                }
                if stdinFdToClose >= 0 {
                    close(stdinFdToClose)
                }

                if !scriptHandles.isEmpty {
                    Self.logger.info("[Ctrl-C] Force-killing \(scriptHandles.count) streaming script command(s)")
                    self.pidLock.withLock {
                        for handle in self.activeScriptCommandHandles {
                            ios_command_kill(handle)
                        }
                    }
                    return
                }

                // Atomic check-and-set: skip if force-kill timer is already pending
                let alreadyScheduled = self.pidLock.withLock {
                    if self.forceKillScheduled { return true }
                    self.forceKillScheduled = true
                    return false
                }
                guard !alreadyScheduled else {
                    Self.logger.debug("[Ctrl-C] Force-kill timer already pending, skipping")
                    return
                }

                // Graceful: ios_kill() calls signal handler directly on main thread
                DispatchQueue.main.async {
                    ios_switchSession(sessionPtr)
                    let result = ios_kill()
                    Self.logger.debug("[Ctrl-C] ios_kill() returned \(result)")
                }

                // After 300ms grace period, force-kill if still running.
                // All pointer use is inside pidLock to prevent use-after-free:
                // runExternalCommand clears currentCommand under pidLock before
                // calling ios_command_release, so if we see a non-nil pointer
                // here it is guaranteed to still be valid.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }

                    self.pidLock.withLock {
                        guard let cmd = self.currentCommand else {
                            Self.logger.debug("[Ctrl-C] Force-kill timer: command already finished")
                            return
                        }

                        // Non-blocking check: has command already exited?
                        if ios_command_try_wait(cmd, nil) {
                            Self.logger.debug("[Ctrl-C] Force-kill timer: command exited during grace period")
                            return
                        }

                        // Command still running — force-terminate to unblock ios_command_wait()
                        Self.logger.info("[Ctrl-C] Force-killing command after 300ms grace period")
                        ios_command_kill(cmd)
                    }
                }
            }
        }
    }

    /// Sends input data to the shell
    func sendInput(_ data: Data) {
        guard isRunning else {
            Self.logger.warning("Cannot send input: session not running")
            return
        }

        // Script read prompt: collect characters with basic line editing
        if case .scriptReadPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for char in text {
                let scalar = char.unicodeScalars.first?.value ?? 0
                switch scalar {
                case 0x03: // Ctrl-C
                    readLineContinuation?(nil)
                    readLineContinuation = nil
                    scriptReadBuffer = ""
                    scriptCancellationToken.cancel()
                    return
                case 0x04: // Ctrl-D (EOF)
                    let line = scriptReadBuffer.isEmpty ? nil : scriptReadBuffer
                    scriptReadBuffer = ""
                    sessionMode = .scriptRunning
                    if line != nil { onOutput?("\r\n") }
                    readLineContinuation?(line)
                    readLineContinuation = nil
                    return
                case 0x0D, 0x0A: // Enter
                    let line = scriptReadBuffer
                    scriptReadBuffer = ""
                    sessionMode = .scriptRunning
                    onOutput?("\r\n")
                    readLineContinuation?(line)
                    readLineContinuation = nil
                    return
                case 0x7F, 0x08: // Backspace
                    if !scriptReadBuffer.isEmpty {
                        scriptReadBuffer.removeLast()
                        if !scriptReadSilent {
                            onOutput?("\u{08} \u{08}")
                        }
                    }
                default:
                    if scalar >= 0x20 {
                        scriptReadBuffer.append(char)
                        if !scriptReadSilent {
                            onOutput?(String(char))
                        }
                    }
                }
            }
            return
        }

        // WASM running. Two modes:
        //
        // Raw mode (rootshell_terminal_set_raw(1)): every byte forwarded
        // verbatim, no echo, no translation — vim/less/htop drive their
        // own line editing and need each keystroke.
        //
        // Cooked mode (default): emulate ICANON + ECHO + ICRNL the way a
        // real PTY would. Programs that read with bufio.ReadString('\n')
        // — including rclone's interactive config — depend on this.
        // Without it: terminals send \r on Enter (not \n) so the read
        // hangs, and there's no local echo so users can't see their input.
        if case .wasmRunning = sessionMode {
            let raw = activeWasmRuntime?.current?.isRawMode ?? false
            if !raw && data.count == 1 && data[0] == 0x03 {
                interrupt()
                return
            }
            if raw {
                forwardStdinToWasm(data)
            } else {
                handleCookedModeWasmInput(data)
            }
            return
        }

        // Script running: forward Ctrl-C to interrupt, buffer everything else
        if case .scriptRunning = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for char in text {
                let scalar = char.unicodeScalars.first?.value ?? 0
                if scalar == 0x03 { // Ctrl-C
                    interrupt()
                    return
                }
            }
            // Forward to running command's stdin if one is active
            let (mode, writeFd) = stdinLock.withLock { (inputMode, commandStdinWriteFd) }
            if mode == .commandStdin && writeFd >= 0 {
                _ = data.withUnsafeBytes { buf in
                    Darwin.write(writeFd, buf.baseAddress!, data.count)
                }
            }
            return
        }

        // Route to embedded SSH session if active
        if case .sshSession = sessionMode, let sshSession = embeddedSSHSession {
            // Ctrl-C during connection attempt cancels the connection
            if !sshSession.isRunning && data.count == 1 && data[0] == 0x03 {
                cancelEmbeddedSessionConnection()
                return
            }
            sshSession.sendInput(data)
            return
        }

        // Route to embedded SFTP session if active
        if case .sftpSession = sessionMode, let sftpSession = embeddedSFTPSession {
            if !sftpSession.isConnected && data.count == 1 && data[0] == 0x03 {
                cancelEmbeddedSessionConnection()
                return
            }
            sftpSession.sendInput(data)
            return
        }

        // Route to embedded Mosh session if active
        if case .moshSession = sessionMode, let moshSession = embeddedMoshSession {
            if !moshSession.isRunning && data.count == 1 && data[0] == 0x03 {
                cancelEmbeddedSessionConnection()
                return
            }
            moshSession.sendInput(data)
            return
        }

        // Route to embedded Trzsz session if active
        if case .trzszSession = sessionMode, let trzszSession = embeddedTrzszSession {
            if !trzszSession.isRunning && data.count == 1 && data[0] == 0x03 {
                cancelEmbeddedSessionConnection()
                return
            }
            trzszSession.sendInput(data)
            return
        }

        // Croc: handle Ctrl-C for cancellation, and forward text to prompt handler.
        if case .crocRunning = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for char in text {
                let scalar = char.unicodeScalars.first?.value ?? 0
                if scalar == 0x03 { // Ctrl-C
                    activeCrocCommand?.cancel()
                    return
                }
            }
            // Forward to croc prompt handler if active
            if let handler = crocPromptHandler {
                onOutput?(text) // echo
                if text.contains("\r") || text.contains("\n") {
                    let response = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    crocPromptHandler = nil
                    handler(response)
                }
            }
            return
        }

        // Native vpn command only accepts Ctrl-C for cancellation.
        #if !CHINA_BUILD
        if case .vpnRunning = sessionMode {
            if data.contains(0x03) {
                cancelVPNCommand()
            }
            return
        }
        #endif

        // Native ping session only accepts Ctrl-C for cancellation.
        if case .pingRunning = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for char in text {
                let scalar = char.unicodeScalars.first?.value ?? 0
                if scalar == 0x03 { // Ctrl-C
                    activePingCommand?.cancel()
                    return
                }
            }
            return
        }

        // mtr gets ALL input forwarded directly (TUI mode).
        // mtr handles its own keybindings including q and Ctrl-C.
        if case .mtrRunning = sessionMode {
            activeMtrCommand?.sendInput(data)
            return
        }

        // Native git command only accepts Ctrl-C for cancellation.
        if case .gitRunning = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for char in text {
                let scalar = char.unicodeScalars.first?.value ?? 0
                if scalar == 0x03 { // Ctrl-C
                    activeGitCommand?.cancel()
                    return
                }
            }
            return
        }

        // Helix editor gets ALL input forwarded directly (raw mode).
        // Helix handles its own keybindings including Ctrl-C.
        if case .helixRunning = sessionMode {
            activeHelixCommand?.sendInput(data)
            return
        }

        // rf file browser gets ALL input forwarded directly (raw mode).
        // rf handles its own keybindings including Ctrl-C.
        if case .rfBrowserRunning = sessionMode {
            activeRFCommand?.sendInput(data)
            return
        }

        // Handle password prompt modes (SSH, SCP, SFTP, Mosh, and Trzsz)
        if case .passwordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handlePasswordInput(char)
                }
            }
            return
        }
        if case .scpPasswordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handlePasswordInput(char)
                }
            }
            return
        }
        if case .sftpPasswordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handlePasswordInput(char)
                }
            }
            return
        }
        if case .moshPasswordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handlePasswordInput(char)
                }
            }
            return
        }
        if case .trzszPasswordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handlePasswordInput(char)
                }
            }
            return
        }
        if case .sshCopyIDPasswordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handlePasswordInput(char)
                }
            }
            return
        }
        if case .gitPasswordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handleGitPasswordInput(char)
                }
            }
            return
        }

        // Handle ssh-copy-id transfer mode (Ctrl-C to cancel)
        if case .sshCopyIDTransfer = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for char in text {
                let scalar = char.unicodeScalars.first?.value ?? 0
                if scalar == 0x03 {  // Ctrl-C
                    embeddedSSHCopyID = nil
                    sessionMode = .localShell

                    let cleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
                    inlineSpinnerAnimator?.stop()
                    inlineSpinnerAnimator = nil
                    onOutput?(cleanup)
                    onOutput?("^C\r\n")
                    displayPrompt()
                }
            }
            return
        }

        // Handle SCP transfer mode (Ctrl-C to cancel)
        if case .scpTransfer = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for char in text {
                let scalar = char.unicodeScalars.first?.value ?? 0
                if scalar == 0x03 {  // Ctrl-C
                    // Cancel the transfer first - this clears callbacks and closes connections
                    embeddedSCPTransfer?.cancel()
                    embeddedSCPTransfer = nil

                    // Reset session state so input isn't blocked
                    sessionMode = .localShell

                    // Clean up spinner and show prompt
                    let cleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
                    inlineSpinnerAnimator?.stop()
                    inlineSpinnerAnimator = nil
                    onOutput?(cleanup)
                    onOutput?("^C\r\n")
                    displayPrompt()
                }
            }
            return
        }

        // Handle host key prompt mode
        if case .hostKeyPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handleHostKeyInput(char)
                }
            }
            return
        }

        // Handle save password prompt mode
        if case .savePasswordPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handleSavePasswordInput(char)
                }
            }
            return
        }

        // Handle AI commit prompt mode (commit/edit/abort)
        #if !CHINA_BUILD
        if case .aiCommitPrompt = sessionMode {
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for char in text {
                    self?.handleAICommitPromptInput(char)
                }
            }
            return
        }
        #endif

        // Terminal responses (cursor position reports, etc.) should ALWAYS go to command stdin
        // if a command is running. This bypasses the lineEditor/commandStdin mode check because
        // programs like vim need to receive cursor position reports immediately.
        let termResponseWriteFd = stdinLock.withLock { commandStdinWriteFd }

        if isTerminalResponse(data) && termResponseWriteFd >= 0 {
            Self.logger.debug("[stdin] Terminal response detected (\(data.count) bytes), forwarding to command stdin")
            data.withUnsafeBytes { bufferPtr in
                guard let baseAddress = bufferPtr.baseAddress else { return }
                _ = Darwin.write(termResponseWriteFd, baseAddress, data.count)
            }
            return
        }

        // Check input mode
        let (mode, writeFd) = stdinLock.withLock { (inputMode, commandStdinWriteFd) }

        switch mode {
        case .lineEditor:
            // Process through line editor (existing behavior)
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.processInput(text)
            }

        case .commandStdin:
            guard writeFd >= 0 else {
                Self.logger.warning("[stdin] commandStdin mode but writeFd is \(writeFd)")
                return
            }

            // Check if this is a full-screen command (vim, less, nano, etc.)
            let isFullScreen = fullScreenLock.withLock { isFullScreenCommand }
            let cooked = stdinLock.withLock { cookedStdinActive }

            // Ctrl-D (EOF): always handle immediately regardless of buffer mode.
            // For cooked-mode filters: flush any pending line to the pipe (no trailing \n),
            //   then close the pipe so the command sees EOF.
            // For non-interactive commands: close stdin to signal EOF.
            // For interactive/full-screen commands: forward to program.
            if let firstByte = data.first, firstByte == 0x04 {
                if cooked {
                    let pending = stdinLock.withLock { () -> Data in
                        let p = cookedLineBuffer
                        cookedLineBuffer.removeAll(keepingCapacity: true)
                        cookedStdinActive = false
                        return p
                    }
                    let pendingCount = pending.count
                    if pendingCount > 0 {
                        pending.withUnsafeBytes { bufferPtr in
                            guard let baseAddress = bufferPtr.baseAddress else { return }
                            _ = Darwin.write(writeFd, baseAddress, pendingCount)
                        }
                    }
                    let fdToClose = stdinLock.withLock {
                        let fd = commandStdinWriteFd
                        commandStdinWriteFd = -1
                        return fd
                    }
                    if fdToClose >= 0 {
                        close(fdToClose)
                    }
                    Self.logger.debug("[stdin] Ctrl-D in cooked mode: flushed \(pendingCount) bytes, closed stdin")
                    return
                }

                let isInteractive = interactiveLock.withLock { isCurrentCommandInteractive }

                if !isInteractive {
                    Self.logger.debug("[stdin] Ctrl-D received for non-interactive command, closing stdin pipe to signal EOF")
                    typeAheadBuffer.removeAll()
                    let fdToClose = stdinLock.withLock {
                        let fd = commandStdinWriteFd
                        commandStdinWriteFd = -1  // Prevent further writes
                        return fd
                    }
                    if fdToClose >= 0 {
                        close(fdToClose)
                    }
                    return
                }
                // For interactive commands, fall through to forward Ctrl-D to the program
                Self.logger.debug("[stdin] Ctrl-D received for interactive command, forwarding to program")
            }

            if cooked {
                // ios_system stdin is a raw pipe, not a TTY — no kernel echo and no line
                // discipline. Implement minimal cooked mode here: echo typed chars, buffer
                // a current line, commit on Enter, handle backspace. Ctrl-D is handled in
                // the fast path above. Ctrl-C goes through interrupt() (not sendInput).
                handleCookedStdinInput(data: data, writeFd: writeFd)
                return
            }

            if isFullScreen {
                // Full-screen app needs live stdin. Flush any buffered type-ahead first.
                if !typeAheadBuffer.isEmpty {
                    let buffered = typeAheadBuffer
                    typeAheadBuffer.removeAll()
                    buffered.withUnsafeBytes { bufferPtr in
                        guard let baseAddress = bufferPtr.baseAddress else { return }
                        _ = Darwin.write(writeFd, baseAddress, buffered.count)
                    }
                    let count = buffered.count
                    Self.logger.debug("[stdin] Flushed \(count) bytes of type-ahead to full-screen command")
                }
                // Forward current input directly to full-screen program
                data.withUnsafeBytes { bufferPtr in
                    guard let baseAddress = bufferPtr.baseAddress else { return }
                    let bytesWritten = Darwin.write(writeFd, baseAddress, data.count)
                    if bytesWritten < 0 {
                        Task { @MainActor in
                            Self.logger.error("[stdin] write failed: errno=\(errno)")
                        }
                    }
                }
            } else {
                // Non-full-screen command (git pull, curl, ls, etc.):
                // Buffer input for type-ahead replay when command completes.
                typeAheadBuffer.append(data)
            }
        }
    }

    /// Cooked-mode stdin loop for stdin-consuming filters (bat, cat, grep, ...).
    /// Echoes typed bytes locally, buffers them per line, and commits a whole line
    /// (including trailing `\n`) to the command's stdin pipe on Enter. Backspace
    /// deletes the last byte locally and erases it on screen. Ctrl-D is handled by
    /// the caller. This is the software equivalent of kernel cooked mode, which
    /// ios_system's pipe-based stdin cannot provide.
    nonisolated func handleCookedStdinInput(data: Data, writeFd: Int32) {
        var echo = Data()
        var toSend = Data()

        stdinLock.withLock {
            for byte in data {
                switch byte {
                case 0x04:
                    // Ctrl-D in the middle of a paste/event: treat as plain byte here;
                    // the fast path above only triggers when it's the first byte.
                    cookedLineBuffer.append(byte)
                    echo.append(byte)
                case 0x0D, 0x0A:
                    // Commit current line with LF terminator (pipes expect \n).
                    toSend.append(cookedLineBuffer)
                    toSend.append(0x0A)
                    cookedLineBuffer.removeAll(keepingCapacity: true)
                    echo.append(0x0D)
                    echo.append(0x0A)
                case 0x7F, 0x08:
                    if !cookedLineBuffer.isEmpty {
                        // Pop the trailing UTF-8 scalar as a whole: strip any continuation
                        // bytes (0b10xxxxxx), then the starter. Byte-at-a-time removal would
                        // leave malformed bytes in the buffer for inputs like `é` or emoji.
                        while let last = cookedLineBuffer.last, (last & 0xC0) == 0x80 {
                            cookedLineBuffer.removeLast()
                        }
                        if !cookedLineBuffer.isEmpty {
                            cookedLineBuffer.removeLast()
                        }
                        echo.append(0x08)
                        echo.append(0x20)
                        echo.append(0x08)
                    }
                default:
                    cookedLineBuffer.append(byte)
                    echo.append(byte)
                }
            }
        }

        if !echo.isEmpty {
            outputSink.emit(echo)
        }
        if !toSend.isEmpty {
            toSend.withUnsafeBytes { bufferPtr in
                guard let baseAddress = bufferPtr.baseAddress else { return }
                let written = Darwin.write(writeFd, baseAddress, toSend.count)
                if written < 0 {
                    let err = errno
                    Self.logger.error("[stdin] cooked write failed: errno=\(err)")
                }
            }
        }
    }

    /// Sets the terminal window size
    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        let previousSize = pty.windowSize

        // Update PTY window size (just store it)
        pty.windowSize = size

        // Only propagate size changes when the grid actually changes.
        // Pixel dimensions can change frequently during live resizing without affecting cols/rows.
        if previousSize.rows == size.rows, previousSize.cols == size.cols {
            return
        }

        // Forward to embedded SSH session if active
        if case .sshSession = sessionMode, let sshSession = embeddedSSHSession {
            try sshSession.setSize(size)
        }

        // Forward to embedded Mosh session if active
        if case .moshSession = sessionMode, let moshSession = embeddedMoshSession {
            try moshSession.setSize(size)
        }

        // Forward to embedded Trzsz session if active
        if case .trzszSession = sessionMode, let trzszSession = embeddedTrzszSession {
            try trzszSession.setSize(size)
        }

        // Forward to mtr if active
        if case .mtrRunning = sessionMode {
            activeMtrCommand?.resize(cols: size.cols, rows: size.rows)
        }

        // Forward to Helix editor if active
        if case .helixRunning = sessionMode {
            activeHelixCommand?.resize(cols: size.cols, rows: size.rows)
        }

        // Forward to rf file browser if active
        if case .rfBrowserRunning = sessionMode {
            activeRFCommand?.resize(cols: size.cols, rows: size.rows)
        }

        // Forward to embedded SFTP prompt if active (for line-wrap redraw math)
        if case .sftpSession = sessionMode {
            embeddedSFTPSession?.resize(cols: size.cols, rows: size.rows)
        }

        // Notify ios_system of window size change
        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)
        ios_setWindowSize(Int32(size.cols), Int32(size.rows), sessionPtr)

        // Update COLUMNS and LINES for programs that check env vars
        ios_setenv("COLUMNS", String(size.cols), 1)
        ios_setenv("LINES", String(size.rows), 1)
    }

    /// Rewrites a saved absolute path to use the current Documents directory.
    /// iOS changes the container UUID between app launches, invalidating saved absolute paths.
    ///
    /// Only rewrites paths that match the iOS app container pattern:
    ///   /private/var/mobile/Containers/Data/Application/<UUID>/Documents/...
    /// This prevents accidentally remapping unrelated paths that happen to contain "/Documents/".
    nonisolated static func resolveContainerPath(_ savedPath: String, currentDocumentsPath: String) -> String? {
        // Normalize /private prefix: on iOS, /var is a symlink to /private/var.
        // ios_system may resolve symlinks, producing /private/var/... paths, while
        // FileManager.urls() returns /var/... paths. Strip /private so both forms match.
        let privatePrefix = "/private"
        let normalizedSaved = savedPath.hasPrefix("/private/var/")
            ? String(savedPath.dropFirst(privatePrefix.count)) : savedPath
        let normalizedCurrent = currentDocumentsPath.hasPrefix("/private/var/")
            ? String(currentDocumentsPath.dropFirst(privatePrefix.count)) : currentDocumentsPath

        // Both paths must share the same container prefix up to the UUID component.
        // iOS container paths: <prefix>/Containers/Data/Application/<UUID>/Documents[/...]
        // We verify the saved path has the same structure as the current Documents path,
        // differing only in the UUID segment.
        guard let savedDocsRange = containerDocumentsRange(in: normalizedSaved),
              let currentDocsRange = containerDocumentsRange(in: normalizedCurrent) else {
            return nil
        }

        // Verify the prefix before the UUID is identical (e.g. /var/mobile/Containers/Data/Application/)
        let savedPrefix = normalizedSaved[normalizedSaved.startIndex..<savedDocsRange.prefixEnd]
        let currentPrefix = normalizedCurrent[normalizedCurrent.startIndex..<currentDocsRange.prefixEnd]
        guard savedPrefix == currentPrefix else { return nil }

        // Extract relative path after Documents/
        let afterDocs = normalizedSaved[savedDocsRange.documentsEnd...]
        if afterDocs.isEmpty {
            // Return original (not normalized) current path so it matches FileManager's form
            return currentDocumentsPath
        }
        // afterDocs starts with "/" — append to original current path
        return currentDocumentsPath + afterDocs
    }

    /// Locates the container structure in an iOS sandbox path.
    /// Returns the index after ".../Application/" (prefixEnd) and after ".../Documents" (documentsEnd),
    /// or nil if the path doesn't match the container pattern.
    private nonisolated static func containerDocumentsRange(in path: String) -> (prefixEnd: String.Index, documentsEnd: String.Index)? {
        let marker = "/Containers/Data/Application/"
        guard let markerRange = path.range(of: marker) else { return nil }
        let prefixEnd = markerRange.upperBound  // right after "Application/"

        // Skip past the UUID segment (next "/" after the UUID)
        let afterPrefix = path[prefixEnd...]
        guard let slashAfterUUID = afterPrefix.firstIndex(of: "/") else { return nil }

        // Verify the next segment is "Documents"
        let afterUUID = path[slashAfterUUID...]  // "/Documents" or "/Documents/..."
        guard afterUUID.hasPrefix("/Documents") else { return nil }
        let documentsEnd = path.index(slashAfterUUID, offsetBy: "/Documents".count)

        // Must be exactly "/Documents" (end of string) or "/Documents/" (followed by subpath)
        if documentsEnd < path.endIndex && path[documentsEnd] != "/" {
            return nil
        }

        return (prefixEnd: prefixEnd, documentsEnd: documentsEnd)
    }

    deinit {
        // Cancel shell task
        shellTask?.cancel()
    }
}

// MARK: - Auth banner card

extension LocalShellSession: SSHAuthBannerCardProviding {
    /// Overrides the default to also retire the embedded session's own copy —
    /// otherwise a still-authenticating session would replay the dismissed
    /// banner to the next subscriber.
    func dismissAuthBannerCard() {
        authBannerCardModel.clear()
        currentAuthBannerProvider?.dismissAuthBannerCard()
    }
}

#endif // !targetEnvironment(macCatalyst)
