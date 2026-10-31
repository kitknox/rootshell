//
//  SFTPSession.swift
//  rootshell
//
//  Interactive SFTP session managing connection and subcommand execution
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOFoundationCompat
import NIOSSH
import os.log

/// Error types for SFTP operations
nonisolated enum SFTPError: LocalizedError {
    case connectionFailed(host: String, underlying: Error?)
    case authenticationFailed(host: String)
    case notConnected
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case directoryNotEmpty(path: String)
    case isADirectory(path: String)
    case notADirectory(path: String)
    case pathOutsideSandbox(path: String)
    case transferFailed(file: String, reason: String)
    case invalidPath(String)
    case invalidArguments(String)
    case noMatchingFiles(pattern: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let host, _):
            return "Failed to connect to \(host)"
        case .authenticationFailed(let host):
            return "Authentication failed for \(host)"
        case .notConnected:
            return "Not connected to server"
        case .fileNotFound(let path):
            return "No such file or directory: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .directoryNotEmpty(let path):
            return "Directory not empty: \(path)"
        case .isADirectory(let path):
            return "\(path): is a directory"
        case .notADirectory(let path):
            return "\(path): not a directory"
        case .pathOutsideSandbox(let path):
            return "\(path): outside the accessible area (only Documents and bookmarked locations are available)"
        case .transferFailed(let file, let reason):
            return "Transfer failed for \(file): \(reason)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .invalidArguments(let msg):
            return msg
        case .noMatchingFiles(let pattern):
            return "No match for \(pattern)"
        case .cancelled:
            return "Operation cancelled"
        }
    }

    /// Map from SFTP error to SFTPError
    static func from(sftpError: Error, path: String) -> SFTPError {
        let description = String(describing: sftpError).lowercased()

        if description.contains("no such file") || description.contains("enoent") || description.contains("not found") {
            return .fileNotFound(path: path)
        } else if description.contains("permission denied") || description.contains("eacces") {
            return .permissionDenied(path: path)
        } else if description.contains("not empty") {
            return .directoryNotEmpty(path: path)
        } else if description.contains("is a directory") {
            return .isADirectory(path: path)
        }

        return .transferFailed(file: path, reason: sftpError.localizedDescription)
    }
}

/// Progress state for SFTP file transfers
struct SFTPTransferProgress: Sendable {
    enum State: Sendable {
        case transferring(currentFile: String)
        case completed
        case failed(Error)
    }

    var state: State
    var currentFile: String = ""
    var currentFileIndex: Int = 0
    var totalFiles: Int = 0
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var startTime: Date = Date()

    var percentComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes) * 100
    }

    var throughput: Double {  // bytes/second
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0 else { return 0 }
        return Double(bytesTransferred) / elapsed
    }
}

/// Interactive SFTP session managing connection and subcommand execution
@MainActor
final class SFTPSession {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SFTPSession")

    // MARK: - Configuration

    let config: SSHConfig

    // MARK: - Connection State

    private var sshClient: SSHClient?
    private var jumpClient: SSHClient?
    private var sftpClient: SFTPClient?
    private(set) var isConnected = false
    private var stopRequested = false

    // MARK: - Directory State

    private var remoteWorkingDirectory: String = "~"
    private var localWorkingDirectory: String

    /// App Documents path == shell HOME == local sandbox root. Computed once.
    private lazy var documentsPath: String =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path

    // MARK: - Line Editing State

    private let lineEditor = LineEditor()
    private var history: [String] = []
    private var historyIndex: Int = -1
    private var savedBuffer: String = ""
    private var escapeBuffer = ""

    /// Fixed input prompt. Width is measured in display cells at redraw time.
    private let promptText = "sftp> "
    /// Current terminal width in columns; updated via `resize(cols:rows:)`.
    private var terminalCols = 80
    /// Physical cursor row (relative to the input-start row) the last `redrawLine()`
    /// left the cursor on. Tracked so the next redraw moves up to the input start by
    /// the exact amount, even when the line wraps across terminal rows.
    private var renderedCursorRow = 0

    // MARK: - Tab Completion State

    private var completionSuggestions: [String] = []
    private var completionIndex: Int = 0
    private var lastTabTime: Date?
    private var lastCompletionPrefix: String = ""

    // MARK: - Transfer Progress State

    private let transferChunkSize = 512 * 1024
    private let progressEmitInterval: TimeInterval = 0.1
    private let progressEmitBytesInterval: Int64 = 512 * 1024
    private var lastProgressEmit: Date = .distantPast
    private var lastProgressBytes: Int64 = 0

    // MARK: - Callbacks

    var onOutput: (@Sendable (String) -> Void)?
    var onProgress: ((SFTPTransferProgress) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    /// Keyboard-interactive (RFC 4256) challenge callback (2FA/OTP/PAM). nil = cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    // MARK: - Subcommand definitions

    private let subcommands = [
        "ls", "lls", "cd", "lcd", "pwd", "lpwd",
        "get", "put", "mkdir", "rmdir", "rm",
        "rename", "chmod", "help", "?", "exit", "quit", "bye"
    ]

    // MARK: - Initialization

    init(config: SSHConfig, localWorkingDirectory: String) {
        self.config = config
        self.localWorkingDirectory = localWorkingDirectory
    }

    // MARK: - Lifecycle

    /// Start the SFTP session by connecting and opening SFTP subsystem
    func start() async throws {
        stopRequested = false
        let host = config.host
        Self.logger.info("Starting SFTP session to \(host)")

        // If start() throws anywhere — including the `throwIfCancelled()`
        // checkpoints below — we must close any SSH/SFTP clients that
        // connectSSH() / openSFTP() may have populated *after* the user
        // already invoked stop(). stop()'s own cleanup() captures whatever
        // properties were set at that instant; if they were still nil at
        // that point, the freshly-assigned clients would otherwise leak
        // their NIO channels until ARC reaped this SFTPSession.
        var succeeded = false
        defer {
            if !succeeded {
                cleanup()
            }
        }

        // Connect SSH
        try await connectSSH()
        try throwIfCancelled()

        // Open SFTP subsystem
        guard let client = sshClient else {
            throw SFTPError.connectionFailed(host: config.host, underlying: nil)
        }

        do {
            sftpClient = try await client.openSFTP()
        } catch {
            throw SFTPError.connectionFailed(host: config.host, underlying: error)
        }
        try throwIfCancelled()

        // Get initial remote working directory
        do {
            let homePath = try await sftpClient!.getRealPath(atPath: ".")
            remoteWorkingDirectory = SFTPOperations.normalizePath(homePath)
        } catch {
            // Fall back to ~ if we can't resolve home
            remoteWorkingDirectory = "~"
        }
        try throwIfCancelled()

        isConnected = true
        succeeded = true

        // Display welcome message and prompt
        let welcomeMessage = "Connected to \(host).\r\n"
        onOutput?(welcomeMessage)
        displayPrompt()
    }

    /// Stop the SFTP session and clean up
    func stop() {
        Self.logger.info("Stopping SFTP session")
        stopRequested = true
        isConnected = false
        cleanup()
    }

    private func throwIfCancelled() throws {
        if stopRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    // MARK: - Terminal Size

    /// Update the terminal width used for line-wrap math. The terminal reflows the
    /// in-flight (soft-wrapped) line to the new width and keeps the cursor on its
    /// glyph, so re-derive the physical cursor row under the new width — otherwise
    /// the next redraw would move up by a row count computed for the old width.
    func resize(cols: UInt16, rows: UInt16) {
        terminalCols = max(1, Int(cols))
        renderedCursorRow = promptLayout().cursorRow
    }

    // MARK: - Input Handling

    /// Process input data from the terminal
    func sendInput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        processInput(text)
    }

    private func processInput(_ text: String) {
        if escapeBuffer.isEmpty && text.hasPrefix("\u{1b}") {
            escapeBuffer = text
            checkEscapeSequence()
            return
        } else if !escapeBuffer.isEmpty {
            escapeBuffer += text
            checkEscapeSequence()
            return
        }

        for char in text {
            handleCharacterInput(char)
        }
    }

    private func handleCharacterInput(_ char: Character) {
        let scalar = char.unicodeScalars.first?.value ?? 0

        switch scalar {
        case 0x0D, 0x0A: // Enter/Return
            handleEnter()

        case 0x09: // Tab
            handleTab()

        case 0x7F, 0x08: // Backspace / Delete
            handleBackspace()

        case 0x01: // Ctrl-A (beginning of line)
            handleCtrlA()

        case 0x05: // Ctrl-E (end of line)
            handleCtrlE()

        case 0x0B: // Ctrl-K (kill to end)
            handleCtrlK()

        case 0x15: // Ctrl-U (kill line)
            handleCtrlU()

        case 0x17: // Ctrl-W (delete word backward)
            handleCtrlW()

        case 0x0C: // Ctrl-L (clear screen)
            handleCtrlL()

        case 0x04: // Ctrl-D (EOF)
            handleCtrlD()

        case 0x10: // Ctrl-P (previous in history)
            handleUpArrow()

        case 0x0E: // Ctrl-N (next in history)
            handleDownArrow()

        case 0x03: // Ctrl-C
            handleCtrlC()

        case 0x1B: // ESC - start of escape sequence
            escapeBuffer = "\u{1b}"

        default:
            // Accept any printable grapheme (CJK, emoji, accented Latin) — measured
            // in display cells at redraw time. Excludes C0 controls (handled above)
            // and DEL (0x7F). Mirrors the main shell's filter.
            if !char.isNewline && (char == " " || (!char.isWhitespace && scalar >= 0x20 && scalar != 0x7F)) {
                insertCharacter(char)
            }
        }
    }

    private func insertCharacter(_ char: Character) {
        stopHistoryNavigation()
        clearCompletionState()
        lineEditor.insertText(String(char))
        redrawLine()
    }

    private func handleEnter() {
        onOutput?("\r\n")

        let command = lineEditor.consume().trimmingCharacters(in: .whitespaces)

        stopHistoryNavigation()
        clearCompletionState()

        if !command.isEmpty {
            if history.isEmpty || history.last != command {
                history.append(command)
            }
        }

        // Execute the command
        Task { @MainActor in
            await executeSubcommand(command)
        }
    }

    private func handleBackspace() {
        if lineEditor.deleteBackward() {
            stopHistoryNavigation()
            clearCompletionState()
            redrawLine()
        }
    }

    private func handleDelete() {
        if lineEditor.deleteForward() {
            stopHistoryNavigation()
            clearCompletionState()
            redrawLine()
        }
    }

    private func handleTab() {
        Task { @MainActor in
            await performTabCompletion()
        }
    }

    private func handleCtrlC() {
        onOutput?("^C\r\n")
        lineEditor.clear()
        stopHistoryNavigation()
        clearCompletionState()
        displayPrompt()
    }

    private func handleCtrlD() {
        if lineEditor.buffer.isEmpty {
            // Exit on Ctrl-D at empty prompt
            onOutput?("\r\n")
            onComplete?()
        }
    }

    private func handleCtrlU() {
        if lineEditor.deleteToStart() {
            stopHistoryNavigation()
            clearCompletionState()
            redrawLine()
        }
    }

    private func handleCtrlK() {
        if lineEditor.deleteToEnd() {
            stopHistoryNavigation()
            clearCompletionState()
            redrawLine()
        }
    }

    private func handleCtrlW() {
        if lineEditor.deleteWordBackward() {
            stopHistoryNavigation()
            clearCompletionState()
            redrawLine()
        }
    }

    private func handleCtrlL() {
        onOutput?("\u{1B}[2J\u{1B}[H")
        redrawLine()
    }

    private func handleCtrlA() {
        if lineEditor.moveCursorToStart() {
            redrawLine()
        }
    }

    private func handleCtrlE() {
        if lineEditor.moveCursorToEnd() {
            redrawLine()
        }
    }

    private func handleArrowLeft() {
        if lineEditor.moveCursorLeft() {
            redrawLine()
        }
    }

    private func handleArrowRight() {
        if lineEditor.moveCursorRight() {
            redrawLine()
        }
    }

    private func handleWordLeft() {
        if lineEditor.moveCursorToPreviousWord() {
            redrawLine()
        }
    }

    private func handleWordRight() {
        if lineEditor.moveCursorToNextWord() {
            redrawLine()
        }
    }

    private func stopHistoryNavigation() {
        historyIndex = -1
        savedBuffer = ""
    }

    private func checkEscapeSequence() {
        if escapeBuffer == "\u{1b}[A" {
            handleUpArrow()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[B" {
            handleDownArrow()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[C" {
            handleArrowRight()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[D" {
            handleArrowLeft()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[H" || escapeBuffer == "\u{1b}[1~" {
            handleCtrlA()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[F" || escapeBuffer == "\u{1b}[4~" {
            handleCtrlE()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}[3~" {
            handleDelete()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}b" {
            handleWordLeft()
            escapeBuffer = ""
        } else if escapeBuffer == "\u{1b}f" {
            handleWordRight()
            escapeBuffer = ""
        } else if escapeBuffer.count > 10 {
            escapeBuffer = ""
        }
    }

    // MARK: - History Navigation

    func handleUpArrow() {
        guard !history.isEmpty else { return }

        if historyIndex == -1 {
            savedBuffer = lineEditor.buffer
            historyIndex = history.count - 1
        } else if historyIndex > 0 {
            historyIndex -= 1
        } else {
            return
        }

        replaceLineWith(history[historyIndex])
    }

    func handleDownArrow() {
        guard historyIndex >= 0 else { return }

        if historyIndex < history.count - 1 {
            historyIndex += 1
            replaceLineWith(history[historyIndex])
        } else {
            historyIndex = -1
            replaceLineWith(savedBuffer)
        }
    }

    private func replaceLineWith(_ text: String) {
        lineEditor.setBuffer(text)
        clearCompletionState()
        redrawLine()
    }

    /// Display-cell layout of `promptText + buffer` at the current terminal width.
    /// All values are in display cells (CJK/emoji occupy 2 columns but 1 Character).
    /// `cursorRow` is clamped to the last drawn row: at an exact column-width
    /// boundary the raw row would read one past the content, a position the cursor
    /// can never actually occupy.
    private func promptLayout() -> (totalRows: Int, cursorRow: Int, cursorCol: Int) {
        let promptWidth = DisplayWidth.width(of: promptText)   // "sftp> " = 6 cells
        let term = max(1, terminalCols)
        let totalRows = CursorTracker.calculateTotalRows(
            promptSecondLinePrefix: promptWidth,
            bufferLength: lineEditor.displayWidth,
            terminalWidth: term)
        let (row, col) = CursorTracker.calculateCursorPosition(
            promptSecondLinePrefix: promptWidth,
            bufferCursorPosition: lineEditor.cursorColumn,
            terminalWidth: term)
        return (totalRows, min(row, totalRows - 1), col)
    }

    private func redrawLine() {
        let buffer = lineEditor.buffer
        let layout = promptLayout()

        var out = ""
        // Move up to the input-start row (the prompt has no info bar above it),
        // clear the whole input area, then redraw prompt + buffer.
        if renderedCursorRow > 0 { out += "\u{1b}[\(renderedCursorRow)A" }
        out += "\r\u{1b}[J"
        out += promptText + buffer

        // When the cursor is at the end of the buffer, printing already left it in
        // the right place (including the deferred-wrap state at an exact row
        // boundary). Repositioning would round-trip through column 0 and misplace
        // it there. Only reposition for mid-line edits.
        if lineEditor.widthAfterCursor > 0 {
            out += CursorTracker.cursorPositionSequence(
                totalRows: layout.totalRows,
                targetRow: layout.cursorRow,
                targetCol: layout.cursorCol)
        }
        onOutput?(out)
        renderedCursorRow = layout.cursorRow
    }

    // MARK: - Tab Completion

    private func performTabCompletion() async {
        let now = Date()

        // Determine what we're completing
        let (prefix, range, context) = analyzeCompletionContext()

        // Check if this is a double-tab (cycle through suggestions)
        let isDoubleTap = lastTabTime != nil &&
            now.timeIntervalSince(lastTabTime!) < 0.5 &&
            lastCompletionPrefix == prefix &&
            !completionSuggestions.isEmpty

        lastTabTime = now
        lastCompletionPrefix = prefix

        if isDoubleTap {
            // Cycle to next suggestion
            completionIndex = (completionIndex + 1) % completionSuggestions.count
            applySuggestion(completionSuggestions[completionIndex], context: context, range: range)
            return
        }

        // Get new suggestions (this awaits a network round-trip for remote paths).
        let fetched = await getSuggestions(prefix: prefix, context: context)

        // Re-snapshot the completion context. If the user typed/deleted/moved
        // the cursor during the await, the original range/prefix is stale —
        // drop the fetched suggestions rather than apply them to a buffer that
        // no longer matches what the user is completing.
        let (currentPrefix, currentRange, currentContext) = analyzeCompletionContext()
        guard currentPrefix == prefix, currentRange == range, currentContext == context else {
            clearCompletionState()
            return
        }

        completionSuggestions = fetched
        completionIndex = 0

        guard !completionSuggestions.isEmpty else {
            // Bell for no matches
            onOutput?("\u{07}")
            return
        }

        if completionSuggestions.count == 1 {
            // Single match - apply it
            applySuggestion(completionSuggestions[0], context: context, range: range)
        } else {
            // Multiple matches - find common prefix and apply
            let commonPrefix = findCommonPrefix(completionSuggestions)
            if commonPrefix.count > prefix.count {
                applySuggestion(commonPrefix, context: context, range: range)
            } else {
                // Show first suggestion
                applySuggestion(completionSuggestions[0], context: context, range: range)
            }
        }
    }

    private enum CompletionContext: Equatable {
        case subcommand
        case remotePath(afterCommand: String)
        case localPath(afterCommand: String)
    }

    private func analyzeCompletionContext() -> (prefix: String, range: Range<Int>, context: CompletionContext) {
        let buffer = lineEditor.buffer
        let cursorPos = lineEditor.cursorPosition
        let beforeCursor = String(buffer.prefix(cursorPos))
        let tokens = tokenize(beforeCursor)
        // Quote/escape-aware so a partially-typed name containing spaces (e.g.
        // `my\ fi` or `"my fi`) is one token, not split on the embedded space.
        // The range spans the *whole* current token (including a closing quote
        // after the cursor) so completing it can't leave an unbalanced quote that
        // swallows the following argument.
        let (range, prefix) = currentTokenRange(buffer, cursorPos: cursorPos)

        // The current token is the command itself only when nothing but whitespace
        // precedes it. Otherwise the first token is the command and we're completing
        // an argument — this stays correct even when an empty quoted token (e.g.
        // `get "`) is dropped by tokenize(), which the trailing-space heuristic got
        // wrong.
        let beforeToken = buffer.prefix(range.lowerBound)
        let isCommandToken = beforeToken.allSatisfy { $0.isWhitespace }

        guard !isCommandToken, let command = tokens.first?.lowercased() else {
            return (prefix, range, .subcommand)
        }

        let remotePathCommands = ["cd", "get", "rm", "rmdir", "chmod", "ls", "rename"]
        let localPathCommands = ["put", "lcd", "lls"]

        if remotePathCommands.contains(command) {
            return (prefix, range, .remotePath(afterCommand: command))
        } else if localPathCommands.contains(command) {
            return (prefix, range, .localPath(afterCommand: command))
        }

        return (prefix, range, .subcommand)
    }

    private func getSuggestions(prefix: String, context: CompletionContext) async -> [String] {
        switch context {
        case .subcommand:
            return getSubcommandSuggestions(prefix: prefix)
        case .remotePath:
            return await getRemotePathSuggestions(prefix: prefix)
        case .localPath:
            return getLocalPathSuggestions(prefix: prefix)
        }
    }

    private func getSubcommandSuggestions(prefix: String) -> [String] {
        if prefix.isEmpty {
            return subcommands
        }
        return subcommands.filter { $0.hasPrefix(prefix.lowercased()) }
    }

    private func getRemotePathSuggestions(prefix: String) async -> [String] {
        guard let sftp = sftpClient else { return [] }

        let (dir, partial) = splitPath(prefix)
        let searchDir: String

        if dir.isEmpty {
            searchDir = remoteWorkingDirectory
        } else if dir.hasPrefix("/") {
            searchDir = dir
        } else {
            searchDir = joinRemotePath(remoteWorkingDirectory, dir)
        }

        do {
            let nameMessages = try await sftp.listDirectory(atPath: searchDir)
            var matches: [String] = []

            for nameMessage in nameMessages {
                for component in nameMessage.components {
                    let filename = component.filename
                    guard filename != "." && filename != ".." else { continue }

                    let lowerFilename = filename.lowercased()
                    let lowerPartial = partial.lowercased()

                    if partial.isEmpty || lowerFilename.hasPrefix(lowerPartial) {
                        // Check if directory to add trailing slash
                        let fullPath = joinRemotePath(searchDir, filename)
                        var attrs = component.attributes
                        if attrs.permissions == nil, let fetched = try? await sftp.getAttributes(at: fullPath) {
                            attrs = fetched
                        }
                        let isDir = isDirectory(attrs)

                        let completion: String
                        if dir.isEmpty {
                            completion = filename
                        } else {
                            completion = dir + (dir.hasSuffix("/") ? "" : "/") + filename
                        }

                        matches.append(isDir ? completion + "/" : completion)
                    }
                }
            }

            return matches.sorted()
        } catch {
            return []
        }
    }

    private func getLocalPathSuggestions(prefix: String) -> [String] {
        let (dir, partial) = splitPath(prefix)
        let searchDir: String

        if dir.isEmpty {
            searchDir = localWorkingDirectory
        } else {
            // Normalize & sandbox-validate every prefix (absolute, ~, or
            // relative) so a relative `../../` can't list outside the boundary.
            // Out-of-sandbox / invalid dirs throw -> offer no suggestions.
            guard let resolved = try? expandLocalPath(dir) else { return [] }
            searchDir = resolved
        }

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: searchDir) else {
            return []
        }

        var matches: [String] = []
        for filename in contents {
            let lowerFilename = filename.lowercased()
            let lowerPartial = partial.lowercased()

            if partial.isEmpty || lowerFilename.hasPrefix(lowerPartial) {
                let fullPath = (searchDir as NSString).appendingPathComponent(filename)
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)

                let completion: String
                if dir.isEmpty {
                    completion = filename
                } else {
                    completion = dir + (dir.hasSuffix("/") ? "" : "/") + filename
                }

                matches.append(isDir.boolValue ? completion + "/" : completion)
            }
        }

        return matches.sorted()
    }

    private func applySuggestion(_ suggestion: String, context: CompletionContext, range: Range<Int>) {
        let replacement: String

        switch context {
        case .subcommand:
            let buffer = lineEditor.buffer
            let cursorPos = lineEditor.cursorPosition
            let beforeCursor = String(buffer.prefix(cursorPos))
            let tokens = tokenize(beforeCursor)
            // Subcommand names never contain spaces; append one once the name is
            // complete so the user can start typing the first argument.
            if tokens.count <= 1 && !beforeCursor.hasSuffix(" ") {
                replacement = suggestion + " "
            } else {
                replacement = suggestion
            }
        case .remotePath, .localPath:
            // Escape spaces/quotes so the inserted filename round-trips through
            // tokenize() as a single argument when the command runs.
            replacement = escapePath(suggestion)
        }

        lineEditor.replaceText(in: range, with: replacement)
        clearCompletionState()
        redrawLine()
    }

    private func findCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first

        for string in strings.dropFirst() {
            while !string.lowercased().hasPrefix(prefix.lowercased()) && !prefix.isEmpty {
                prefix = String(prefix.dropLast())
            }
        }

        return prefix
    }

    private func clearCompletionState() {
        completionSuggestions = []
        completionIndex = 0
    }

    // MARK: - Subcommand Execution

    private func executeSubcommand(_ command: String) async {
        guard !command.isEmpty else {
            displayPrompt()
            return
        }

        let tokens = tokenize(command)
        guard let name = tokens.first?.lowercased() else {
            displayPrompt()
            return
        }

        let args = Array(tokens.dropFirst())

        do {
            switch name {
            case "ls", "dir":
                try await doLs(args: args)
            case "lls":
                try doLls(args: args)
            case "cd":
                try await doCd(args: args)
            case "lcd":
                try doLcd(args: args)
            case "pwd":
                try await doPwd()
            case "lpwd":
                doLpwd()
            case "get":
                try await doGet(args: args)
            case "put":
                try await doPut(args: args)
            case "mkdir":
                try await doMkdir(args: args)
            case "rmdir":
                try await doRmdir(args: args)
            case "rm", "delete":
                try await doRm(args: args)
            case "rename", "mv":
                try await doRename(args: args)
            case "chmod":
                try await doChmod(args: args)
            case "help", "?":
                doHelp()
            case "exit", "quit", "bye":
                onComplete?()
                return
            default:
                onOutput?("Invalid command.\r\n")
            }
        } catch {
            onOutput?("\(SSHBanner.terminalSafe(error.localizedDescription))\r\n")
        }

        displayPrompt()
    }

    // MARK: - Directory Commands

    private func doLs(args: [String]) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        // Parse flags
        var showLong = false
        var showAll = false
        var targetArg: String?

        for arg in args {
            if arg.hasPrefix("-") {
                for char in arg.dropFirst() {
                    switch char {
                    case "l": showLong = true
                    case "a": showAll = true
                    default: break
                    }
                }
            } else {
                targetArg = arg
            }
        }

        // Check for glob pattern in the target argument
        var globPattern: String?
        var targetPath = remoteWorkingDirectory

        if let target = targetArg {
            if containsGlob(target) {
                let resolved = try await resolveRemoteGlobPattern(target)
                let (dir, pat) = splitGlobPattern(resolved)
                targetPath = dir
                globPattern = pat
            } else {
                targetPath = try await resolveRemotePath(target)
            }
        }

        let nameMessages: [SFTPMessage.Name]
        do {
            nameMessages = try await sftp.listDirectory(atPath: targetPath)
        } catch {
            throw SFTPError.from(sftpError: error, path: targetPath)
        }

        // When glob pattern starts with '.', include dotfiles even without -a
        let globIncludesDotfiles = globPattern?.hasPrefix(".") ?? false

        var entries: [(name: String, longname: String?)] = []

        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }
                if !showAll && !globIncludesDotfiles && filename.hasPrefix(".") { continue }

                // Apply glob filter if present
                if let pattern = globPattern {
                    guard matchesGlob(filename, pattern: pattern) else { continue }
                }

                if showLong {
                    entries.append((filename, component.longname))
                } else {
                    entries.append((filename, nil))
                }
            }
        }

        if let pattern = globPattern, entries.isEmpty {
            throw SFTPError.noMatchingFiles(pattern: targetArg ?? pattern)
        }

        // Sort alphabetically
        entries.sort { $0.name.lowercased() < $1.name.lowercased() }

        if showLong {
            for (_, longname) in entries {
                if let longname = longname {
                    onOutput?(SSHBanner.terminalSafe(longname) + "\r\n")
                }
            }
        } else {
            for (name, _) in entries {
                onOutput?(SSHBanner.terminalSafe(name) + "\r\n")
            }
        }
    }

    private func doLls(args: [String]) throws {
        // Parse flags
        var showLong = false
        var showAll = false
        var targetPath = localWorkingDirectory

        for arg in args {
            if arg.hasPrefix("-") {
                for char in arg.dropFirst() {
                    switch char {
                    case "l": showLong = true
                    case "a": showAll = true
                    default: break
                    }
                }
            } else {
                targetPath = try expandLocalPath(arg)
            }
        }

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: targetPath) else {
            onOutput?("Cannot access '\(targetPath)': No such file or directory\r\n")
            return
        }

        var entries: [(name: String, isDir: Bool, size: Int64, modDate: Date?)] = []

        for filename in contents {
            if !showAll && filename.hasPrefix(".") { continue }

            let fullPath = (targetPath as NSString).appendingPathComponent(filename)
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)

            var size: Int64 = 0
            var modDate: Date?
            if let attrs = try? fileManager.attributesOfItem(atPath: fullPath) {
                size = attrs[.size] as? Int64 ?? 0
                modDate = attrs[.modificationDate] as? Date
            }

            entries.append((filename, isDir.boolValue, size, modDate))
        }

        entries.sort { $0.name.lowercased() < $1.name.lowercased() }

        if showLong {
            for (name, isDir, size, modDate) in entries {
                let sizeStr = formatSize(size)
                let dateStr = formatDate(modDate)
                let typeChar = isDir ? "d" : "-"
                onOutput?("\(typeChar)rw-r--r-- \(sizeStr) \(dateStr) \(name)\r\n")
            }
        } else {
            for (name, _, _, _) in entries {
                onOutput?(name + "\r\n")
            }
        }
    }

    private func doCd(args: [String]) async throws {
        guard sftpClient != nil else { throw SFTPError.notConnected }

        let newPath: String
        if args.isEmpty {
            // cd with no args goes to home
            newPath = "~"
        } else {
            newPath = args[0]
        }

        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        let canonicalPath: String
        do {
            canonicalPath = SFTPOperations.normalizePath(
                try await sftp.getRealPath(atPath: try await resolveRemotePath(newPath))
            )
        } catch {
            throw SFTPError.from(sftpError: error, path: newPath)
        }

        // Verify it's a directory
        let attrs = try await sftp.getAttributes(at: canonicalPath)
        guard isDirectory(attrs) else {
            throw SFTPError.notADirectory(path: newPath)
        }

        remoteWorkingDirectory = canonicalPath
    }

    private func doLcd(args: [String]) throws {
        let newPath: String
        if args.isEmpty {
            // No arg -> HOME (iOS/visionOS: Documents; Catalyst: user home).
            newPath = try expandLocalPath("~")
        } else {
            newPath = try expandLocalPath(args[0])
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newPath, isDirectory: &isDir) else {
            throw SFTPError.fileNotFound(path: args.first ?? newPath)
        }
        guard isDir.boolValue else {
            throw SFTPError.notADirectory(path: args.first ?? newPath)
        }

        localWorkingDirectory = newPath
        onOutput?("Local directory now: \(newPath)\r\n")
    }

    private func doPwd() async throws {
        onOutput?("Remote working directory: \(SSHBanner.terminalSafe(remoteWorkingDirectory))\r\n")
    }

    private func doLpwd() {
        onOutput?("Local working directory: \(localWorkingDirectory)\r\n")
    }

    // MARK: - File Transfer Commands

    private func doGet(args: [String]) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        var recursive = false
        var remotePath: String?
        var localPath: String?

        for arg in args {
            if arg == "-r" || arg == "-R" {
                recursive = true
            } else if remotePath == nil {
                remotePath = arg
            } else {
                localPath = arg
            }
        }

        guard let remote = remotePath else {
            onOutput?("usage: get [-r] remote-path [local-path]\r\n")
            return
        }

        // Glob expansion
        if containsGlob(remote) {
            let resolvedPattern = try await resolveRemoteGlobPattern(remote)
            let matches = try await expandRemoteGlob(pattern: resolvedPattern)
            guard !matches.isEmpty else {
                throw SFTPError.noMatchingFiles(pattern: remote)
            }

            let destDir = try expandLocalPath(localPath ?? localWorkingDirectory)

            // Ensure destination is a directory
            var destIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: destDir, isDirectory: &destIsDir) {
                if !destIsDir.boolValue {
                    throw SFTPError.notADirectory(path: localPath ?? localWorkingDirectory)
                }
            } else {
                try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            }

            // Pre-compute accurate totals by enumerating directory contents
            var totalFiles = 0
            var totalBytes: Int64 = 0
            var matchIsDir: [Bool] = []
            for match in matches {
                let attrs = try await sftp.getAttributes(at: match)
                let isDir = isDirectory(attrs)
                matchIsDir.append(isDir)
                if isDir && recursive {
                    let dirFiles = try await enumerateRemoteDirectory(path: match)
                    totalFiles += dirFiles.count
                    totalBytes = totalBytes.addingSaturating(dirFiles.saturatingByteTotal { $0.size })
                } else if !isDir {
                    totalFiles += 1
                    totalBytes = totalBytes.addingSaturating(Int64(clamping: attrs.size ?? 0))
                }
            }

            var progress = SFTPTransferProgress(
                state: .transferring(currentFile: ""),
                currentFile: "",
                currentFileIndex: 0,
                totalFiles: totalFiles,
                bytesTransferred: 0,
                totalBytes: totalBytes,
                startTime: Date()
            )
            lastProgressEmit = .distantPast
            lastProgressBytes = 0
            emitProgress(progress, force: true)

            do {
                for (index, match) in matches.enumerated() {
                    let fileName = (match as NSString).lastPathComponent
                    let localDest = (destDir as NSString).appendingPathComponent(fileName)
                    progress.currentFile = fileName
                    progress.state = .transferring(currentFile: fileName)
                    emitProgress(progress, force: true)

                    if matchIsDir[index] {
                        if recursive {
                            onOutput?("Fetching \(SSHBanner.terminalSafe(match))/ to \(SSHBanner.terminalSafe(localDest))/\r\n")
                            try await downloadDirectory(remotePath: match, localPath: localDest, progress: &progress, updateTotals: false)
                        } else {
                            throw SFTPError.isADirectory(path: fileName)
                        }
                    } else {
                        progress.currentFileIndex += 1
                        onOutput?("Fetching \(SSHBanner.terminalSafe(match)) to \(SSHBanner.terminalSafe(localDest))\r\n")
                        try await downloadFile(remotePath: match, localPath: localDest, progress: &progress)
                    }
                }

                progress.state = .completed
                emitProgress(progress, force: true)
            } catch {
                progress.state = .failed(error)
                emitProgress(progress, force: true)
                throw error
            }
            return
        }

        // Single file path (no glob)
        let resolvedRemote = try await resolveRemotePath(remote)
        let local = localPath ?? (localWorkingDirectory as NSString)
            .appendingPathComponent((resolvedRemote as NSString).lastPathComponent)
        let expandedLocal = try expandLocalPath(local)

        let attrs = try await sftp.getAttributes(at: resolvedRemote)
        let isDir = isDirectory(attrs)

        if isDir && !recursive {
            throw SFTPError.isADirectory(path: remote)
        }

        var progress = SFTPTransferProgress(
            state: .transferring(currentFile: ""),
            currentFile: "",
            currentFileIndex: 0,
            totalFiles: 0,
            bytesTransferred: 0,
            totalBytes: 0,
            startTime: Date()
        )
        lastProgressEmit = .distantPast
        lastProgressBytes = 0

        do {
            if isDir {
                try await downloadDirectory(remotePath: resolvedRemote, localPath: expandedLocal, progress: &progress)
            } else {
                let fileName = (resolvedRemote as NSString).lastPathComponent
                progress.currentFile = fileName
                progress.currentFileIndex = 1
                progress.totalFiles = 1
                progress.totalBytes = Int64(clamping: attrs.size ?? 0)
                progress.state = .transferring(currentFile: fileName)
                emitProgress(progress, force: true)

                try await downloadFile(remotePath: resolvedRemote, localPath: expandedLocal, progress: &progress)
            }

            progress.state = .completed
            emitProgress(progress, force: true)
        } catch {
            progress.state = .failed(error)
            emitProgress(progress, force: true)
            throw error
        }

        onOutput?("Fetching \(SSHBanner.terminalSafe(remote)) to \(SSHBanner.terminalSafe(localPath ?? local))\r\n")
    }

    private func doPut(args: [String]) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        var recursive = false
        var localPath: String?
        var remotePath: String?

        for arg in args {
            if arg == "-r" || arg == "-R" {
                recursive = true
            } else if localPath == nil {
                localPath = arg
            } else {
                remotePath = arg
            }
        }

        guard let local = localPath else {
            onOutput?("usage: put [-r] local-path [remote-path]\r\n")
            return
        }

        // Glob expansion
        if containsGlob(local) {
            let resolvedPattern = try resolveLocalGlobPattern(local)
            let matches = try expandLocalGlob(pattern: resolvedPattern)
            guard !matches.isEmpty else {
                throw SFTPError.noMatchingFiles(pattern: local)
            }

            let destDir = try await resolveRemotePath(remotePath ?? remoteWorkingDirectory)

            // Ensure remote destination is a directory
            do {
                let destAttrs = try await sftp.getAttributes(at: destDir)
                if !isDirectory(destAttrs) {
                    throw SFTPError.notADirectory(path: remotePath ?? remoteWorkingDirectory)
                }
            } catch let error as SFTPError {
                throw error
            } catch {
                // Directory doesn't exist — create it
                try await createRemoteDirectoryIfNeeded(path: destDir)
            }

            // Pre-compute accurate totals by enumerating directory contents
            var totalFiles = 0
            var totalBytes: Int64 = 0
            var matchIsDirFlags: [Bool] = []
            for match in matches {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: match, isDirectory: &isDir)
                matchIsDirFlags.append(isDir.boolValue)
                if isDir.boolValue && recursive {
                    let dirFiles = try enumerateLocalDirectory(path: match)
                    totalFiles += dirFiles.count
                    totalBytes = totalBytes.addingSaturating(dirFiles.saturatingByteTotal { $0.size })
                } else if !isDir.boolValue {
                    totalFiles += 1
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: match)[.size]) as? Int64 ?? 0
                    totalBytes += fileSize
                }
            }

            var progress = SFTPTransferProgress(
                state: .transferring(currentFile: ""),
                currentFile: "",
                currentFileIndex: 0,
                totalFiles: totalFiles,
                bytesTransferred: 0,
                totalBytes: totalBytes,
                startTime: Date()
            )
            lastProgressEmit = .distantPast
            lastProgressBytes = 0
            emitProgress(progress, force: true)

            do {
                for (index, match) in matches.enumerated() {
                    let fileName = (match as NSString).lastPathComponent
                    let remoteDest = joinRemotePath(destDir, fileName)
                    progress.currentFile = fileName
                    progress.state = .transferring(currentFile: fileName)
                    emitProgress(progress, force: true)

                    if matchIsDirFlags[index] {
                        if recursive {
                            onOutput?("Uploading \(match)/ to \(remoteDest)/\r\n")
                            try await uploadDirectory(localPath: match, remotePath: remoteDest, progress: &progress, updateTotals: false)
                        } else {
                            throw SFTPError.isADirectory(path: fileName)
                        }
                    } else {
                        progress.currentFileIndex += 1
                        onOutput?("Uploading \(match) to \(remoteDest)\r\n")
                        try await uploadFile(localPath: match, remotePath: remoteDest, progress: &progress)
                    }
                }

                progress.state = .completed
                emitProgress(progress, force: true)
            } catch {
                progress.state = .failed(error)
                emitProgress(progress, force: true)
                throw error
            }
            return
        }

        // Single file path (no glob)
        let expandedLocal = try expandLocalPath(local)
        let remote = remotePath ?? (remoteWorkingDirectory as NSString)
            .appendingPathComponent((expandedLocal as NSString).lastPathComponent)
        let resolvedRemote = try await resolveRemotePath(remote)

        // Check if file or directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedLocal, isDirectory: &isDir) else {
            throw SFTPError.fileNotFound(path: local)
        }

        if isDir.boolValue && !recursive {
            throw SFTPError.isADirectory(path: local)
        }

        var progress = SFTPTransferProgress(
            state: .transferring(currentFile: ""),
            currentFile: "",
            currentFileIndex: 0,
            totalFiles: 0,
            bytesTransferred: 0,
            totalBytes: 0,
            startTime: Date()
        )
        lastProgressEmit = .distantPast
        lastProgressBytes = 0

        do {
            if isDir.boolValue {
                try await uploadDirectory(localPath: expandedLocal, remotePath: resolvedRemote, progress: &progress)
            } else {
                let fileName = (expandedLocal as NSString).lastPathComponent
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: expandedLocal)[.size]) as? Int64 ?? 0
                progress.currentFile = fileName
                progress.currentFileIndex = 1
                progress.totalFiles = 1
                progress.totalBytes = fileSize
                progress.state = .transferring(currentFile: fileName)
                emitProgress(progress, force: true)

                try await uploadFile(localPath: expandedLocal, remotePath: resolvedRemote, progress: &progress)
            }

            progress.state = .completed
            emitProgress(progress, force: true)
        } catch {
            progress.state = .failed(error)
            emitProgress(progress, force: true)
            throw error
        }

        onOutput?("Uploading \(local) to \((remotePath ?? remote))\r\n")
    }

    private func downloadFile(remotePath: String, localPath: String, progress: inout SFTPTransferProgress) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        // Ensure local directory exists
        let localDir = (localPath as NSString).deletingLastPathComponent
        if !localDir.isEmpty {
            try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        }

        let fileURL = URL(fileURLWithPath: localPath)
        FileManager.default.createFile(atPath: localPath, contents: nil)

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 0)
        } catch {
            throw SFTPError.transferFailed(file: localPath, reason: error.localizedDescription)
        }

        defer {
            try? handle.close()
        }

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: .read)
        } catch {
            throw SFTPError.from(sftpError: error, path: remotePath)
        }

        do {
            let attrs = try? await file.readAttributes()
            let fileBaseBytesTransferred = progress.bytesTransferred
            var progressCopy = progress
            try await PipelinedTransfer.downloadFile(file: file, fileSize: attrs?.size, to: handle) { currentFileBytes in
                progressCopy.bytesTransferred = fileBaseBytesTransferred + currentFileBytes
                self.emitProgress(progressCopy)
            }
            progress.bytesTransferred = progressCopy.bytesTransferred

            try await file.close()
        } catch let error as PipelinedTransfer.LocalIOError {
            try? await file.close()
            throw SFTPError.transferFailed(file: localPath, reason: error.underlying.localizedDescription)
        } catch let error as SFTPError {
            try? await file.close()
            throw error
        } catch {
            try? await file.close()
            throw SFTPError.from(sftpError: error, path: remotePath)
        }
    }

    private func downloadDirectory(remotePath: String, localPath: String, progress: inout SFTPTransferProgress, updateTotals: Bool = true) async throws {
        guard sftpClient != nil else { throw SFTPError.notConnected }

        try FileManager.default.createDirectory(atPath: localPath, withIntermediateDirectories: true)

        let files = try await enumerateRemoteDirectory(path: remotePath)
        if updateTotals {
            progress.totalFiles = files.count
            progress.totalBytes = files.saturatingByteTotal { $0.size }
        }

        for (index, entry) in files.enumerated() {
            let relative = relativePath(from: remotePath, fullPath: entry.path)
            let localFilePath = (localPath as NSString).appendingPathComponent(relative)

            progress.currentFileIndex = updateTotals ? index + 1 : progress.currentFileIndex + 1
            progress.currentFile = relative.isEmpty ? entry.path : relative
            progress.state = .transferring(currentFile: progress.currentFile)
            emitProgress(progress, force: true)

            try await downloadFile(remotePath: entry.path, localPath: localFilePath, progress: &progress)
        }
    }

    private func uploadFile(localPath: String, remotePath: String, progress: inout SFTPTransferProgress) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        // Ensure remote directory exists
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        if !remoteDir.isEmpty && remoteDir != "." && remoteDir != "/" {
            try await createRemoteDirectoryIfNeeded(path: remoteDir)
        }

        let fileURL = URL(fileURLWithPath: localPath)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw SFTPError.fileNotFound(path: localPath)
        }

        defer {
            try? handle.close()
        }

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: [.create, .write, .truncate])
        } catch {
            throw SFTPError.from(sftpError: error, path: remotePath)
        }

        do {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size]) as? UInt64
            let fileBaseBytesTransferred = progress.bytesTransferred
            var progressCopy = progress
            try await PipelinedTransfer.uploadFile(file: file, from: handle, fileSize: fileSize) { currentFileBytes in
                progressCopy.bytesTransferred = fileBaseBytesTransferred + currentFileBytes
                self.emitProgress(progressCopy)
            }
            progress.bytesTransferred = progressCopy.bytesTransferred

            try await file.close()
        } catch let error as PipelinedTransfer.LocalIOError {
            try? await file.close()
            throw SFTPError.transferFailed(file: localPath, reason: error.underlying.localizedDescription)
        } catch let error as SFTPError {
            try? await file.close()
            throw error
        } catch {
            try? await file.close()
            throw SFTPError.from(sftpError: error, path: remotePath)
        }
    }

    private func uploadDirectory(localPath: String, remotePath: String, progress: inout SFTPTransferProgress, updateTotals: Bool = true) async throws {
        guard sftpClient != nil else { throw SFTPError.notConnected }

        try await createRemoteDirectoryIfNeeded(path: remotePath)

        let files = try enumerateLocalDirectory(path: localPath)
        if updateTotals {
            progress.totalFiles = files.count
            progress.totalBytes = files.saturatingByteTotal { $0.size }
        }

        for (index, entry) in files.enumerated() {
            let remoteFilePath = joinRemotePath(remotePath, entry.relativePath)

            progress.currentFileIndex = updateTotals ? index + 1 : progress.currentFileIndex + 1
            progress.currentFile = entry.relativePath
            progress.state = .transferring(currentFile: progress.currentFile)
            emitProgress(progress, force: true)

            try await uploadFile(localPath: entry.path, remotePath: remoteFilePath, progress: &progress)
        }
    }

    private struct LocalFileEntry {
        let path: String
        let relativePath: String
        let size: UInt64
    }

    private func enumerateLocalDirectory(path: String) throws -> [LocalFileEntry] {
        var results: [LocalFileEntry] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            throw SFTPError.fileNotFound(path: path)
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                let attrs = try? fileManager.attributesOfItem(atPath: fullPath)
                let size = attrs?[.size] as? UInt64 ?? 0
                results.append(LocalFileEntry(path: fullPath, relativePath: relativePath, size: size))
            }
        }

        return results
    }

    private func enumerateRemoteDirectory(path: String) async throws -> [(path: String, size: UInt64)] {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        return try await SFTPOperations.enumerateRemoteDirectory(sftp: sftp, path: path)
    }

    private func relativePath(from base: String, fullPath: String) -> String {
        SFTPOperations.relativePath(from: base, fullPath: fullPath)
    }

    private func emitProgress(_ progress: SFTPTransferProgress, force: Bool = false) {
        let now = Date()
        let bytesSinceLast = max(Int64(0), progress.bytesTransferred - lastProgressBytes)
        if !force &&
            now.timeIntervalSince(lastProgressEmit) < progressEmitInterval &&
            bytesSinceLast < progressEmitBytesInterval {
            return
        }
        lastProgressEmit = now
        lastProgressBytes = progress.bytesTransferred

        if let onProgress = onProgress {
            onProgress(progress)
        } else {
            outputProgressLine(progress)
        }
    }

    private func outputProgressLine(_ progress: SFTPTransferProgress) {
        switch progress.state {
        case .transferring(let file):
            let displayFile = SSHBanner.terminalSafe(file.isEmpty ? progress.currentFile : file)
            let throughput = formatThroughput(progress.throughput)
            let message: String

            if progress.totalBytes > 0 {
                let pct = Int(progress.percentComplete)
                if progress.totalFiles > 1 {
                    message = "\(displayFile) (\(progress.currentFileIndex)/\(progress.totalFiles)) \(pct)% | \(throughput)"
                } else {
                    message = "\(displayFile) \(pct)% | \(throughput)"
                }
            } else {
                let transferred = formatByteCount(progress.bytesTransferred)
                if progress.totalFiles > 1 {
                    message = "\(displayFile) (\(progress.currentFileIndex)/\(progress.totalFiles)) \(transferred) | \(throughput)"
                } else {
                    message = "\(displayFile) \(transferred) | \(throughput)"
                }
            }

            onOutput?("\r\(message)\u{1b}[K")

        case .completed, .failed:
            onOutput?("\r\u{1b}[K\r\n")
        }
    }

    private func formatThroughput(_ bps: Double) -> String {
        SFTPOperations.formatThroughput(bps)
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        SFTPOperations.formatByteCount(bytes)
    }

    // MARK: - File Management Commands

    private func doMkdir(args: [String]) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        guard let path = args.first else {
            onOutput?("usage: mkdir path\r\n")
            return
        }

        let resolved = try await resolveRemotePath(path)

        do {
            try await sftp.createDirectory(atPath: resolved)
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }
    }

    private func doRmdir(args: [String]) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        guard let path = args.first else {
            onOutput?("usage: rmdir path\r\n")
            return
        }

        let resolved = try await resolveRemotePath(path)

        do {
            try await sftp.rmdir(at: resolved)
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }
    }

    private func doRm(args: [String]) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        guard let path = args.first else {
            onOutput?("usage: rm path\r\n")
            return
        }

        if containsGlob(path) {
            let resolvedPattern = try await resolveRemoteGlobPattern(path)
            let matches = try await expandRemoteGlob(pattern: resolvedPattern)
            guard !matches.isEmpty else {
                throw SFTPError.noMatchingFiles(pattern: path)
            }

            for match in matches {
                let fileName = (match as NSString).lastPathComponent
                // Skip directories — rm only removes files (use rmdir for directories)
                let attrs = try await sftp.getAttributes(at: match)
                if isDirectory(attrs) {
                    onOutput?("Skipping directory: \(SSHBanner.terminalSafe(fileName))\r\n")
                    continue
                }
                onOutput?("Removing \(SSHBanner.terminalSafe(fileName))\r\n")
                do {
                    try await sftp.remove(at: match)
                } catch {
                    throw SFTPError.from(sftpError: error, path: fileName)
                }
            }
            return
        }

        let resolved = try await resolveRemotePath(path)

        do {
            try await sftp.remove(at: resolved)
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }
    }

    private func doRename(args: [String]) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        guard args.count >= 2 else {
            onOutput?("usage: rename oldpath newpath\r\n")
            return
        }

        let oldPath = try await resolveRemotePath(args[0])
        let newPath = try await resolveRemotePath(args[1])

        do {
            try await sftp.rename(at: oldPath, to: newPath)
        } catch {
            throw SFTPError.from(sftpError: error, path: args[0])
        }
    }

    private func doChmod(args: [String]) async throws {
        // Note: Citadel's SFTP client doesn't expose a public setstat method
        // chmod functionality is not available
        onOutput?("chmod: not supported by this SFTP client\r\n")
    }

    // MARK: - Help

    private func doHelp() {
        let help = """
Available commands:
  cd [path]         Change remote directory
  lcd [path]        Change local directory
  pwd               Print remote working directory
  lpwd              Print local working directory
  ls [-la] [path]   List remote directory (wildcards in filename)
  lls [-la] [path]  List local directory
  get [-r] remote [local]   Download file (wildcards in filename)
  put [-r] local [remote]   Upload file (wildcards in filename)
  mkdir path        Create remote directory
  rmdir path        Remove remote directory
  rm path           Remove remote file (wildcards in filename)
  rename old new    Rename remote file
  chmod mode path   Change remote file permissions
  help              Show this help
  exit              Close connection

"""
        onOutput?(help.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    // MARK: - SSH Connection

    private func connectSSH() async throws {
        Self.logger.info("Connecting to \(self.config.host):\(self.config.port) for SFTP")

        let result = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: onHostKeyValidation,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
        self.sshClient = result.client
        self.jumpClient = result.jumpClient
    }

    private func cleanup() {
        // Capture refs into locals BEFORE nil'ing the @MainActor-isolated
        // properties — otherwise the Task body below runs after the synchronous
        // nil-assignments and `sftpClient?.close()` short-circuits on nil,
        // leaking the underlying NIO channels.
        let sftpToClose = sftpClient
        let sshToClose = sshClient
        let jumpToClose = jumpClient
        sftpClient = nil
        sshClient = nil
        jumpClient = nil

        // Bounded close — Citadel's close future parks on a TCP FIN/RST ack
        // that may never arrive (network gone, server unreachable). Match the
        // CitadelSSHSession.cleanup() pattern.
        Task {
            do {
                try await withTimeout(seconds: 2) {
                    try? await sftpToClose?.close()
                }
            } catch {
                Self.logger.warning("SFTP close timed out — abandoning")
            }
            do {
                try await withTimeout(seconds: 2) {
                    try? await sshToClose?.close()
                }
            } catch {
                Self.logger.warning("SSH close timed out — abandoning")
            }
            do {
                try await withTimeout(seconds: 2) {
                    try? await jumpToClose?.close()
                }
            } catch {
                Self.logger.warning("Jump client close timed out — abandoning")
            }
        }
    }

    // MARK: - Glob Utilities

    /// Check if a path contains glob wildcard characters
    private func containsGlob(_ path: String) -> Bool {
        SFTPOperations.containsGlob(path, escapeAware: true)
    }

    private func splitGlobPattern(_ path: String) -> (directory: String, pattern: String) {
        SFTPOperations.splitGlobPattern(path)
    }

    private func matchesGlob(_ name: String, pattern: String) -> Bool {
        SFTPOperations.matchesGlob(name, pattern: pattern, escapeAware: true)
    }

    private func resolveRemoteGlobPattern(_ pattern: String) async throws -> String {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        return try await SFTPOperations.resolveRemoteGlobPattern(pattern, cwd: remoteWorkingDirectory, sftp: sftp)
    }

    /// Resolve a local glob pattern's directory portion while keeping the filename glob untouched.
    /// Throws if glob characters appear in non-final path components.
    private func resolveLocalGlobPattern(_ pattern: String) throws -> String {
        let (dir, filePattern) = splitGlobPattern(pattern)
        if containsGlob(dir) {
            throw SFTPError.invalidArguments("Wildcards only supported in the last path component: \(pattern)")
        }
        let expandedDir = try expandLocalPath(dir)
        return (expandedDir as NSString).appendingPathComponent(filePattern)
    }

    private func expandRemoteGlob(pattern: String) async throws -> [String] {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        return try await SFTPOperations.expandRemoteGlob(sftp: sftp, pattern: pattern, cwd: remoteWorkingDirectory)
    }

    /// Expand a local glob pattern into matching full paths
    private func expandLocalGlob(pattern: String) throws -> [String] {
        let (directory, filePattern) = splitGlobPattern(pattern)
        let includeDotfiles = filePattern.hasPrefix(".")

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            throw SFTPError.fileNotFound(path: directory)
        }

        var matchingPaths: [String] = []
        for entry in entries {
            if !includeDotfiles && entry.hasPrefix(".") { continue }
            if matchesGlob(entry, pattern: filePattern) {
                matchingPaths.append((directory as NSString).appendingPathComponent(entry))
            }
        }

        return matchingPaths.sorted()
    }

    // MARK: - Path Utilities

    private func resolveRemotePath(_ path: String) async throws -> String {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        return try await SFTPOperations.resolvePath(path, cwd: remoteWorkingDirectory, sftp: sftp)
    }

    private func joinRemotePath(_ base: String, _ component: String) -> String {
        SFTPOperations.joinPath(base, component)
    }

    private func splitPath(_ path: String) -> (directory: String, filename: String) {
        SFTPOperations.splitPath(path)
    }

    /// Expand a local path argument, then (on iOS/visionOS) validate it stays
    /// inside the local shell's sandbox (Documents + bookmarked locations),
    /// throwing `SFTPError.pathOutsideSandbox` for escapes. This keeps the SFTP
    /// local commands (`lcd`/`lls`/`get`/`put`) consistent with the shell's own
    /// `cd`, which is jailed by `ios_setMiniRoot` + `ios_setAllowedPaths`.
    ///
    /// Mac Catalyst has no ios_system miniRoot jail (the whole bookmark /
    /// allowed-paths backend is compiled `#if !targetEnvironment(macCatalyst)`),
    /// so there it expands with full-filesystem semantics and never confines.
    private func expandLocalPath(_ rawPath: String) throws -> String {
        // Turn escaped glob metacharacters back into literals for the real path.
        let path = SFTPOperations.unescapePath(rawPath)

        #if targetEnvironment(macCatalyst)
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if path.hasPrefix("/") {
            return path
        }
        return (localWorkingDirectory as NSString).appendingPathComponent(path)
        #else
        let expanded: String
        if path == "~" {
            // HOME == Documents (set by the shell), not the app container root.
            expanded = documentsPath
        } else if path.hasPrefix("~/") {
            expanded = (documentsPath as NSString)
                .appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            // Empty or relative: resolve against the current local cwd.
            expanded = (localWorkingDirectory as NSString).appendingPathComponent(path)
        }

        // Collapse ./.. (and resolve symlinks for existing paths) so the sandbox
        // check can't be fooled by `Documents/../../etc`.
        let normalized = (expanded as NSString).standardizingPath
        guard BookmarkedLocationsManager.shared.isAccessiblePath(normalized) else {
            throw SFTPError.pathOutsideSandbox(path: rawPath)
        }
        return normalized
        #endif
    }

    private func createRemoteDirectoryIfNeeded(path: String) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }
        try await SFTPOperations.createDirectoryIfNeeded(sftp: sftp, path: path)
    }

    private func isDirectory(_ attrs: SFTPFileAttributes) -> Bool {
        SFTPOperations.isDirectory(attrs)
    }

    // MARK: - Formatting Helpers (for local ls)

    private func formatPermissions(_ mode: UInt32) -> String {
        SFTPOperations.formatPermissions(mode)
    }

    private func formatSize(_ size: Int64) -> String {
        SFTPOperations.formatSize(size)
    }

    private func formatDate(_ date: Date?) -> String {
        SFTPOperations.formatDate(date)
    }

    // MARK: - Tokenization

    private func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character?
        var escaped = false

        for char in command {
            if escaped {
                // Re-emit a canonical escape sequence: keep the backslash on an
                // escaped backslash (`\\` = a literal backslash) and on escaped glob
                // metacharacters (`\*` = a literal `*`). This lets downstream parsing
                // tell `foo\*` (the file `foo*`) apart from `foo\\*` (a literal
                // backslash then a `*` wildcard). Unescape everything else.
                if char == "\\" || char == "*" || char == "?" || char == "[" || char == "]" {
                    current.append("\\")
                }
                current.append(char)
                escaped = false
            } else if char == "\\" && inQuote != "'" {
                // Backslash escapes the next char (outside single quotes), so an
                // escaped space stays part of the filename token.
                escaped = true
            } else if let quote = inQuote {
                if char == quote {
                    inQuote = nil
                } else {
                    // Quoting makes every enclosed char literal (POSIX), so escape
                    // backslash + metacharacters to keep the token an unambiguous
                    // escape sequence — e.g. `rm "foo*"` targets the file `foo*`.
                    if char == "\\" || char == "*" || char == "?" || char == "[" || char == "]" {
                        current.append("\\")
                    }
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                inQuote = char
            } else if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        // Trailing backslash with no following char: keep it as a literal (matches
        // SCPCommandParser) so `rm foo\` targets `foo\` rather than dropping to `foo`.
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Backslash-escape a path so `tokenize` parses it back to exactly this string.
    /// Mirrors how OpenSSH's sftp escapes filenames during completion. Glob
    /// metacharacters are escaped too, so a completed name like `my*file` is treated
    /// as a literal filename rather than a wildcard.
    private func escapePath(_ path: String) -> String {
        var result = ""
        for ch in path {
            if ch == "\\" || ch == "\"" || ch == "'" || ch.isWhitespace
                || ch == "*" || ch == "?" || ch == "[" || ch == "]" {
                result.append("\\")
            }
            result.append(ch)
        }
        return result
    }

    /// Locate the in-progress token under the cursor for completion, using the same
    /// quote + backslash rules as `tokenize`. Returns the token's start offset in
    /// `text` and its unescaped value, so a partially-typed name like `my\ fi`
    /// completes against `my fi` and is replaced as a whole (not split on the space).
    private func completionToken(_ text: String) -> (start: Int, value: String, active: Bool) {
        let chars = Array(text)
        var tokenStart = chars.count
        var value = ""
        var inToken = false
        var inQuote: Character?
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if !inToken {
                if ch.isWhitespace { i += 1; continue }
                inToken = true
                tokenStart = i
                value = ""
                inQuote = nil
            }

            if ch == "\\" && inQuote != "'" && i + 1 < chars.count {
                value.append(chars[i + 1])
                i += 2
                continue
            }
            if let quote = inQuote {
                if ch == quote { inQuote = nil } else { value.append(ch) }
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" {
                inQuote = ch
                i += 1
                continue
            }
            if ch.isWhitespace {
                inToken = false
                i += 1
                continue
            }
            value.append(ch)
            i += 1
        }

        // `active` is true when the cursor sits inside a token, even an empty one
        // such as a just-opened quote (`get "`). That case has an empty value but
        // still owns the opening quote, so the range must cover it.
        return inToken ? (tokenStart, value, true) : (chars.count, "", false)
    }

    /// Buffer range of the whole token under the cursor, plus its unescaped value
    /// up to the cursor (used to match suggestions). The range starts at the token
    /// start (found from the text before the cursor) and extends forward to the
    /// token's true end — past a closing quote or any in-token chars after the
    /// cursor — so replacing it with a completion can never leave an unbalanced
    /// quote. When the cursor sits at a whitespace boundary (no active token) the
    /// range is an empty insertion point so the following argument is untouched.
    private func currentTokenRange(_ buffer: String, cursorPos: Int) -> (range: Range<Int>, prefix: String) {
        let chars = Array(buffer)
        let bound = min(cursorPos, chars.count)
        let (start, prefix, active) = completionToken(String(chars[0..<bound]))

        guard active else {
            return (bound..<bound, "")
        }

        // Walk forward from the token start with the same quote/escape rules as
        // `tokenize` to find where the token ends (unquoted, unescaped whitespace).
        var i = start
        var inQuote: Character?
        var escaped = false
        while i < chars.count {
            let ch = chars[i]
            if escaped {
                escaped = false
            } else if ch == "\\" && inQuote != "'" {
                escaped = true
            } else if let quote = inQuote {
                if ch == quote { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch.isWhitespace {
                break
            }
            i += 1
        }

        return (start..<i, prefix)
    }

    // MARK: - Prompt

    private func displayPrompt() {
        // A fresh prompt starts a new line with the cursor at the input-start row.
        renderedCursorRow = 0
        onOutput?(promptText)
    }
}
