#if !CHINA_BUILD
//
//  AIAgentSession.swift
//  rootshell
//
//  Main AI Agent session coordinator and state machine
//

import Foundation
import Combine
import os.log

/// Type of connection for the AI Agent
enum AIAgentConnectionType: Sendable, Equatable {
    case ssh(SSHConfig)
    case local
}

/// AI Agent session that coordinates LLM interactions, command execution, and state
@Observable
@MainActor
final class AIAgentSession {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AIAgentSession")

    // MARK: - Observable State

    /// Current agent state
    private(set) var state: AIAgentState = .idle

    /// Conversation history (displayed in UI)
    private(set) var messages: [AIAgentMessage] = []

    /// Whether the session is connected to SSH
    private(set) var isConnected = false

    /// Whether a connection attempt is in progress
    private(set) var isConnecting = false

    /// Host fingerprint for context
    private(set) var fingerprint: HostFingerprint?

    /// Current usage statistics
    private(set) var totalTokensUsed: Int = 0

    /// Input tokens sent in the most recent request — proxy for current context-window fill.
    private(set) var lastPromptTokens: Int = 0

    // MARK: - Streaming State

    /// Text being streamed from the AI (displayed in real-time, thinking removed)
    private(set) var streamingText: String?

    /// Thinking content being streamed (displayed in collapsible section)
    private(set) var streamingThinking: String?

    /// Whether we're currently streaming a response
    private(set) var isStreaming: Bool = false

    /// Streaming command output during execution (displayed in real-time)
    private(set) var executingStreamOutput: String?

    // MARK: - Batch Tool Call State

    /// Pending tool calls from batch that haven't been processed yet
    @ObservationIgnored private var pendingToolCalls: [AIToolCall] = []

    /// Accumulated tool results for current batch (sent together when all calls processed)
    @ObservationIgnored private var batchedToolResults: [AIToolResult] = []

    /// Pending file tool call awaiting user approval (call, toolName)
    @ObservationIgnored private var pendingFileToolCall: (AIToolCall, String)?

    // MARK: - Streaming Throttle

    /// Minimum interval between UI updates (100ms = 10 updates/sec)
    /// Reduced from 50ms to lower CPU usage while maintaining smooth visual updates
    private let uiUpdateInterval: CFAbsoluteTime = 0.1

    private nonisolated static let streamingMarkerTailLength = 32

    // MARK: - Streaming Task

    @ObservationIgnored private var streamTask: Task<StreamFinalResult, Error>?
    private final class StreamingUIUpdater: @unchecked Sendable {
        weak var session: AIAgentSession?

        init(session: AIAgentSession) {
            self.session = session
        }
    }

    // MARK: - Dependencies

    /// Connection type for this session
    let connectionType: AIAgentConnectionType

    /// Initial working directory from the terminal (for local connections)
    var initialWorkingDirectory: String?

    /// Closure to fetch the current working directory from the terminal session.
    /// Called during resetToNewChat() to refresh the CWD.
    var workingDirectoryProvider: (() -> String?)?

    /// SSH config (convenience accessor for .ssh connection type)
    var sshConfig: SSHConfig? {
        if case .ssh(let config) = connectionType {
            return config
        }
        return nil
    }

    /// Optional label override. When the terminal's transport is Mosh or Trzsz,
    /// the connectionType collapses to .ssh (the executor dials SSH regardless),
    /// but the UI should still show the roam-style label from the outer config.
    var displayNameOverride: String?

    /// Display name for this session (works for both SSH and local)
    var displayName: String {
        if let displayNameOverride { return displayNameOverride }
        switch connectionType {
        case .ssh(let config):
            return config.displayName
        case .local:
            return "Local Shell"
        }
    }

    @ObservationIgnored private var provider: (any AIProvider)?
    @ObservationIgnored private var executor: AIAgentExecutor?
    @ObservationIgnored private var fingerprintCollector: HostFingerprintCollector?
    @ObservationIgnored private var credentialsObserverTask: Task<Void, Never>?

    #if targetEnvironment(macCatalyst)
    @ObservationIgnored private var localExecutor: CatalystLocalExecutor?
    @ObservationIgnored private var localFingerprintCollector: LocalFingerprintCollector?
    #else
    @ObservationIgnored private var iosLocalExecutor: IOSLocalExecutor?
    @ObservationIgnored private var iosLocalFingerprintCollector: IOSLocalFingerprintCollector?
    /// Bumped by disconnect() so a connect still awaiting its executor can tell
    /// it was abandoned.
    @ObservationIgnored private var connectAttempt = 0
    #endif

    /// Unique identifier for this session
    let id: UUID

    /// Built on the first request and reused until the conversation resets. Fable 5.2 and
    /// Opus 5.5 reject replayed thinking blocks once the system prompt changes.
    private var conversationSystemPrompt: String?

    /// Frozen alongside the system prompt; a changed tool list also invalidates replayed thinking.
    private var conversationTools: [AIAgentTool]?

    /// Available tools for the AI
    private var availableTools: [AIAgentTool] {
        var tools: [AIAgentTool] = [AIAgentTool.executeCommand, AIAgentTool.askUser]
        if case .local = connectionType {
            tools.append(contentsOf: [AIAgentTool.readFile, AIAgentTool.writeFile, AIAgentTool.editFile])
        }
        if AICredentialsManager.shared.webSearchEnabled {
            tools.append(contentsOf: [AIAgentTool.webSearch, AIAgentTool.webFetch])
        }
        return tools
    }

    // MARK: - Initialization

    init(id: UUID = UUID(), connectionType: AIAgentConnectionType) {
        self.id = id
        self.connectionType = connectionType
    }

    /// Convenience initializer for SSH connections (backwards compatibility)
    convenience init(id: UUID = UUID(), sshConfig: SSHConfig) {
        self.init(id: id, connectionType: .ssh(sshConfig))
    }

    deinit {
        // Cancel the credentials observer even if disconnect() was never called.
        // Several UI teardown paths release the session without awaiting an
        // async disconnect, and without this the Task would keep the
        // NotificationCenter async-sequence alive indefinitely.
        credentialsObserverTask?.cancel()
        // Remaining async cleanup still happens in disconnect() for callers
        // that invoke it explicitly.
    }

    // MARK: - Connection Management

    /// Connect to SSH or local executor and configure the AI provider
    func connect() async throws {
        guard !isConnected, !isConnecting else { return }

        isConnecting = true
        defer { isConnecting = false }

        let connectionName: String
        switch connectionType {
        case .ssh(let config):
            connectionName = config.displayName
        case .local:
            connectionName = "local"
        }

        Self.logger.info("Connecting AI Agent session to \(connectionName)")

        // Create the appropriate provider based on selected model
        let selectedModelID = AICredentialsManager.shared.validatedSelectedModelID
        guard !selectedModelID.isEmpty,
              let provider = createProviderForModel(selectedModelID) else {
            throw AIAgentSessionError.notConfigured
        }
        self.provider = provider

        // Rebuild the provider whenever the user edits credentials (API keys,
        // custom provider endpoint/format/model IDs, etc.) so changes apply
        // without requiring an app restart.
        credentialsObserverTask?.cancel()
        credentialsObserverTask = Task { @MainActor [weak self] in
            let stream = NotificationCenter.default.notifications(named: .aiCredentialsChanged)
            for await _ in stream {
                self?.reloadProviderFromCurrentSelection()
            }
        }

        // Create executor based on connection type
        switch connectionType {
        case .ssh(let sshConfig):
            // Create SSH executor and connect
            let sshExecutor = AIAgentExecutor(sshConfig: sshConfig)
            try await sshExecutor.connect()
            self.executor = sshExecutor

            // Create SSH fingerprint collector
            fingerprintCollector = HostFingerprintCollector(executor: sshExecutor)

        case .local:
            #if targetEnvironment(macCatalyst)
            // Create local executor and connect (Mac Catalyst via rootshell-helper)
            let local = CatalystLocalExecutor()
            try await local.connect()
            self.localExecutor = local

            // Create local fingerprint collector
            localFingerprintCollector = LocalFingerprintCollector(executor: local)
            #else
            // Create iOS local executor and connect (via ios_system)
            let iosLocal = IOSLocalExecutor()
            let attempt = connectAttempt
            try await iosLocal.connect(workingDirectory: initialWorkingDirectory)
            // disconnect() ran during the connect and couldn't reach this
            // executor; tear down only it, leaving any newer attempt alone.
            guard attempt == connectAttempt else {
                await iosLocal.disconnect()
                throw CancellationError()
            }
            self.iosLocalExecutor = iosLocal

            // Create iOS fingerprint collector
            iosLocalFingerprintCollector = IOSLocalFingerprintCollector(executor: iosLocal)
            #endif
        }

        isConnected = true

        // Collect fingerprint in background
        Task {
            await collectFingerprint()
        }

        Self.logger.info("AI Agent session connected")
    }

    /// Disconnect from SSH or local executor
    func disconnect() async {
        Self.logger.debug("Disconnecting AI Agent session")

        credentialsObserverTask?.cancel()
        credentialsObserverTask = nil

        provider?.cancel()
        provider = nil
        streamTask?.cancel()
        streamTask = nil

        // Disconnect SSH executor if present
        if let executor = executor {
            await executor.disconnect()
        }
        executor = nil
        fingerprintCollector = nil

        // Disconnect local executor if present
        #if targetEnvironment(macCatalyst)
        if let localExecutor = localExecutor {
            await localExecutor.disconnect()
        }
        localExecutor = nil
        localFingerprintCollector = nil
        #else
        connectAttempt += 1
        if let iosLocalExecutor = iosLocalExecutor {
            await iosLocalExecutor.disconnect()
        }
        iosLocalExecutor = nil
        iosLocalFingerprintCollector = nil
        #endif
        isConnected = false
        isConnecting = false
        state = .idle
    }

    /// Collect or refresh the host fingerprint
    func collectFingerprint(forceRefresh: Bool = false) async {
        do {
            // Collect fingerprint based on connection type
            switch connectionType {
            case .ssh:
                guard let collector = fingerprintCollector else { return }
                fingerprint = try await collector.collect(forceRefresh: forceRefresh)

                // Set SSH executor's shell for login shell command execution
                if let shell = fingerprint?.shell {
                    executor?.sessionShell = shell
                    Self.logger.debug("Set SSH session shell to \(shell)")
                }

            case .local:
                #if targetEnvironment(macCatalyst)
                guard let collector = localFingerprintCollector else { return }
                fingerprint = try await collector.collect(forceRefresh: forceRefresh)

                // Set local executor's shell for login shell command execution
                if let shell = fingerprint?.shell {
                    localExecutor?.sessionShell = shell
                    Self.logger.debug("Set local session shell to \(shell)")
                }
                #else
                guard let collector = iosLocalFingerprintCollector else { return }
                fingerprint = try await collector.collect(forceRefresh: forceRefresh)
                #endif
            }

            Self.logger.debug("Fingerprint collected: \(self.fingerprint?.os ?? "unknown")")
        } catch {
            Self.logger.error("Failed to collect fingerprint: \(error.localizedDescription)")
            // Continue without fingerprint - the agent can still work
        }
    }

    // MARK: - Message Sending

    /// Send a user message to the AI agent
    /// - Parameter text: The user's message
    func sendMessage(_ text: String) async {
        guard isConnected, let provider = provider else {
            state = .error(.configuration("Not connected"))
            return
        }

        guard !state.isBusy else {
            Self.logger.warning("Attempted to send message while busy")
            return
        }

        // Add user message to history
        let userMessage = AIAgentMessage.user(text)
        messages.append(userMessage)

        // Start thinking with streaming
        state = .thinking
        await sendMessageWithStreaming(provider: provider)
    }

    /// Internal method to send message using streaming API
    private func sendMessageWithStreaming(provider: any AIProvider) async {
        // Reset streaming state
        isStreaming = true
        streamingText = ""
        streamingThinking = nil

        let systemPrompt = conversationSystemPrompt ?? buildSystemPrompt()
        conversationSystemPrompt = systemPrompt
        let tools = conversationTools ?? availableTools
        conversationTools = tools

        let stream = provider.sendMessageStream(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools
        )

        do {
            let uiUpdateInterval = uiUpdateInterval
            let updater = StreamingUIUpdater(session: self)
            let task = Task.detached { [updater] in
                try await Self.consumeStream(
                    stream: stream,
                    uiUpdateInterval: uiUpdateInterval
                ) { snapshot in
                    await MainActor.run {
                        guard let session = updater.session else { return }
                        session.streamingText = snapshot.displayText
                        if snapshot.thinkingFromDelta || session.streamingThinking == nil {
                            session.streamingThinking = snapshot.thinkingText
                        }
                    }
                }
            }

            streamTask = task

            let result = try await task.value
            streamTask = nil

            // Track token usage
            if let usage = result.usage {
                totalTokensUsed += usage.totalTokens
                lastPromptTokens = usage.promptTokens
            }

            // NOTE: Store original accumulatedText for API round-trips
            // UI display filtering happens in displayText computed property (AIAgentMessage)
            // Do NOT filter text here - models need their original output preserved

            // A refusal's partial output is discarded rather than kept as an answer.
            if result.finishReason == .contentFilter {
                isStreaming = false
                streamingText = nil
                streamingThinking = nil
                state = .error(.unknown("The model declined this request. Try rephrasing it or switching models."))
                return
            }

            // Determine thinking block to use:
            // - With ordered blocks, those carry the round-trip; show every block's text
            // - Otherwise prefer completedThinkingBlock (has signature for API round-trip)
            // - Fall back to delta-accumulated thinking (no signature - will be stripped on send)
            let thinkingBlock: AIThinkingBlock?
            if result.assistantBlocks != nil {
                thinkingBlock = result.accumulatedThinking.isEmpty
                    ? nil
                    : AIThinkingBlock(content: result.accumulatedThinking, signature: nil)
            } else if let completed = result.completedThinkingBlock {
                thinkingBlock = completed
            } else if !result.accumulatedThinking.isEmpty {
                // Fallback: thinking from deltas only, no signature available
                thinkingBlock = AIThinkingBlock(content: result.accumulatedThinking, signature: nil)
            } else {
                thinkingBlock = nil
            }

            // Tool calls a refusal fallback superseded are absent from the ordered blocks.
            var nativeToolCalls = result.completedToolCalls
            if let blocks = result.assistantBlocks {
                let keptIDs = Set(blocks.compactMap { block -> String? in
                    if case .toolUse(let id) = block { return id }
                    return nil
                })
                nativeToolCalls.removeAll { !keptIDs.contains($0.id) }
            }

            // Parse text-based tool calls ONLY if we didn't get native tool calls
            // (some endpoints output both native AND text format - avoid duplicates)
            var allToolCalls = nativeToolCalls
            if result.completedToolCalls.isEmpty {
                let miniMaxResult = MiniMaxToolCallParser.parse(result.accumulatedText)
                let textToolResult = TextToolCallParser.parse(miniMaxResult.remainingText)

                if !miniMaxResult.toolCalls.isEmpty {
                    Self.logger.debug("Parsed \(miniMaxResult.toolCalls.count) MiniMax tool call(s) from text")
                    allToolCalls.append(contentsOf: miniMaxResult.toolCalls)
                }
                if !textToolResult.toolCalls.isEmpty {
                    Self.logger.debug("Parsed \(textToolResult.toolCalls.count) text-format tool call(s) from text")
                    allToolCalls.append(contentsOf: textToolResult.toolCalls)
                }
            }

            // Debug: Log the full accumulated text before processing
            Self.logger.debug("Final text (\(result.accumulatedText.count) chars), thinking: \(thinkingBlock?.content.count ?? 0) chars, signature: \(thinkingBlock?.signature != nil ? "yes" : "no")")
            Self.logger.debug("Tool calls: \(allToolCalls.count) (native: \(result.completedToolCalls.count))")

            // Build response from accumulated data (original text preserved for API round-trips)
            let response = buildResponseFromStream(
                text: result.accumulatedText,
                toolCalls: allToolCalls,
                usage: result.usage,
                finishReason: result.finishReason
            )

            // Process the response FIRST (adds message to messages array)
            // This ensures MessageBubbleView appears before we clear streaming state,
            // preventing truncation from the race condition where streaming view
            // disappears before the message view appears
            try await processResponse(response, thinking: thinkingBlock, blocks: result.assistantBlocks)

            // Yield to allow SwiftUI to render the new message
            await Task.yield()

            // NOW clear streaming state (StreamingMessageBubbleView will disappear
            // but MessageBubbleView is already visible with full content)
            isStreaming = false
            streamingText = nil
            streamingThinking = nil

        } catch is CancellationError {
            isStreaming = false
            streamingText = nil
            streamingThinking = nil
            streamTask = nil
            lastPromptTokens = 0
        } catch {
            isStreaming = false
            streamingText = nil
            streamingThinking = nil
            streamTask = nil
            lastPromptTokens = 0
            Self.logger.error("AI request failed: \(error.localizedDescription)")
            handleError(error)
        }
    }

    nonisolated private static func containsStreamingMarkers(in text: String) -> Bool {
        if text.range(of: "<think", options: .caseInsensitive) != nil {
            return true
        }
        if text.range(of: "</think", options: .caseInsensitive) != nil {
            return true
        }
        if text.contains("<|tool_call") {
            return true
        }
        if text.contains("<|tool_calls_section_end|>") {
            return true
        }
        if text.range(of: "<minimax:tool_call", options: .caseInsensitive) != nil {
            return true
        }
        return false
    }

    nonisolated private static func buildStreamingDisplay(
        from text: String,
        requiresParsing: Bool
    ) -> ThinkingParser.StreamingParseResult {
        if !requiresParsing {
            return ThinkingParser.StreamingParseResult(
                displayText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                thinkingText: nil
            )
        }

        var displayText = MiniMaxToolCallParser.parseForStreaming(text)
        displayText = TextToolCallParser.parseForStreaming(displayText)
        return ThinkingParser.parseForStreaming(displayText)
    }

    // MARK: - Streaming Consumption (Off-Main)

    private struct StreamSnapshot: Sendable {
        let displayText: String
        let thinkingText: String?
        let thinkingFromDelta: Bool
    }

    private struct StreamFinalResult: Sendable {
        let accumulatedText: String
        let accumulatedThinking: String
        let completedThinkingBlock: AIThinkingBlock?
        let completedToolCalls: [AIToolCall]
        let assistantBlocks: [AIAssistantBlock]?
        let usage: AIUsageStats?
        let finishReason: AIProviderResponse.FinishReason?
    }

    private nonisolated static func consumeStream(
        stream: AsyncThrowingStream<AIProviderStreamEvent, Error>,
        uiUpdateInterval: CFAbsoluteTime,
        onSnapshot: @Sendable @escaping (StreamSnapshot) async -> Void
    ) async throws -> StreamFinalResult {
        var accumulatedText = ""
        var accumulatedThinking = ""
        var completedThinkingBlock: AIThinkingBlock?
        var completedToolCalls: [AIToolCall] = []
        var assistantBlocks: [AIAssistantBlock]?
        // Accumulate tool call arguments during streaming (keyed by item ID)
        // Some providers only send deltas without toolCallComplete events
        var accumulatedToolCallArgs: [String: (name: String?, arguments: String)] = [:]
        var streamingRequiresParsing = false
        var streamingMarkerTail = ""
        var lastEmitTime: CFAbsoluteTime = 0
        var finishReason: AIProviderResponse.FinishReason?
        var usage: AIUsageStats?

        func updateStreamingParsingState(with delta: String) {
            guard !streamingRequiresParsing else { return }
            let combined = streamingMarkerTail + delta
            if containsStreamingMarkers(in: combined) {
                streamingRequiresParsing = true
                streamingMarkerTail = ""
            } else {
                streamingMarkerTail = String(combined.suffix(streamingMarkerTailLength))
            }
        }

        func emitSnapshot(force: Bool = false) async {
            let now = CFAbsoluteTimeGetCurrent()
            if !force, now - lastEmitTime < uiUpdateInterval {
                return
            }
            lastEmitTime = now

            let thinkingResult = buildStreamingDisplay(
                from: accumulatedText,
                requiresParsing: streamingRequiresParsing
            )

            let thinkingText: String?
            let thinkingFromDelta: Bool
            if !accumulatedThinking.isEmpty {
                thinkingText = accumulatedThinking
                thinkingFromDelta = true
            } else {
                thinkingText = thinkingResult.thinkingText
                thinkingFromDelta = false
            }

            await onSnapshot(StreamSnapshot(
                displayText: thinkingResult.displayText,
                thinkingText: thinkingText,
                thinkingFromDelta: thinkingFromDelta
            ))
        }

        for try await event in stream {
            switch event {
            case .textDelta(let delta):
                accumulatedText += delta
                updateStreamingParsingState(with: delta)
                await emitSnapshot()

            case .thinkingDelta(let delta):
                accumulatedThinking += delta
                await emitSnapshot()

            case .thinkingComplete(let thinking, let signature):
                completedThinkingBlock = AIThinkingBlock(content: thinking, signature: signature)
                Self.logger.debug("Thinking block complete: \(thinking.count) chars, signature: \(signature != nil ? "yes" : "no")")

            case .toolCallDelta(let id, let name, let argsDelta):
                // Accumulate tool call arguments for providers that don't send toolCallComplete
                var existing = accumulatedToolCallArgs[id] ?? (name: nil, arguments: "")
                if let name = name {
                    existing.name = name
                }
                existing.arguments += argsDelta
                accumulatedToolCallArgs[id] = existing

            case .toolCallComplete(let toolCall):
                if !completedToolCalls.contains(where: { $0.id == toolCall.id }) {
                    completedToolCalls.append(toolCall)
                    // Remove from accumulated since we got the complete version
                    accumulatedToolCallArgs.removeValue(forKey: toolCall.id)
                    Self.logger.debug("Tool call complete: \(toolCall.name), args: \(toolCall.arguments.prefix(200))")
                } else {
                    Self.logger.debug("Skipping duplicate tool call: \(toolCall.id)")
                }

            case .assistantBlocks(let blocks):
                assistantBlocks = blocks

            case .responseComplete(let responseUsage, let reason):
                usage = responseUsage
                finishReason = reason
                Self.logger.debug("Stream complete, finishReason: \(String(describing: reason)), toolCalls: \(completedToolCalls.count)")

            case .error(let error):
                Self.logger.error("Stream error: \(error.localizedDescription)")
                throw error
            }
        }

        // Build tool calls from accumulated deltas if we didn't get toolCallComplete events
        for (id, accumulated) in accumulatedToolCallArgs {
            guard let name = accumulated.name, !accumulated.arguments.isEmpty else {
                Self.logger.warning("Incomplete tool call from deltas: id=\(id), name=\(accumulated.name ?? "nil")")
                continue
            }
            // Only add if not already in completedToolCalls
            if !completedToolCalls.contains(where: { $0.id == id }) {
                let toolCall = AIToolCall(id: id, name: name, arguments: accumulated.arguments)
                completedToolCalls.append(toolCall)
                Self.logger.debug("Built tool call from deltas: \(name), args: \(accumulated.arguments.prefix(200))")
            }
        }

        await emitSnapshot(force: true)

        return StreamFinalResult(
            accumulatedText: accumulatedText,
            accumulatedThinking: accumulatedThinking,
            completedThinkingBlock: completedThinkingBlock,
            completedToolCalls: completedToolCalls,
            assistantBlocks: assistantBlocks,
            usage: usage,
            finishReason: finishReason
        )
    }

    /// Build an AIProviderResponse from streamed data
    private func buildResponseFromStream(
        text: String,
        toolCalls: [AIToolCall],
        usage: AIUsageStats?,
        finishReason: AIProviderResponse.FinishReason?
    ) -> AIProviderResponse {
        let content: AIProviderResponse.Content
        if !toolCalls.isEmpty && !text.isEmpty {
            content = .textAndToolCalls(text, toolCalls)
        } else if !toolCalls.isEmpty {
            content = .toolCalls(toolCalls)
        } else {
            content = .text(text)
        }

        return AIProviderResponse(
            content: content,
            usage: usage,
            finishReason: finishReason
        )
    }

    // MARK: - Command Approval

    /// Approve and execute a pending command (for manual approval flow)
    func approveCommand() async {
        guard case .awaitingApproval(let command) = state else {
            Self.logger.warning("No command awaiting approval")
            return
        }

        // Check if this is a file tool approval
        if let (call, toolName) = pendingFileToolCall {
            pendingFileToolCall = nil
            executeFileToolCommand(call, toolName: toolName)
            return
        }

        await executeCommand(command)
    }

    /// Execute a command (shared by approveCommand and YOLO mode)
    private func executeCommand(_ command: AIAgentCommand) async {
        // Verify we have an executor
        let hasExecutor: Bool
        switch connectionType {
        case .ssh:
            hasExecutor = executor != nil
        case .local:
            #if targetEnvironment(macCatalyst)
            hasExecutor = localExecutor != nil
            #else
            hasExecutor = iosLocalExecutor != nil
            #endif
        }

        guard hasExecutor else {
            state = .error(.configuration("Not connected"))
            return
        }

        // Transition to executing state and reset streaming output
        state = .executing(command)
        executingStreamOutput = nil

        Self.logger.info("Executing command: \(command.command)")

        do {
            // Execute using the appropriate executor
            let result: CommandExecutionResult
            switch connectionType {
            case .ssh:
                result = try await executor!.executeStreaming(
                    command: command.command
                ) { [weak self] streamOutput in
                    self?.executingStreamOutput = streamOutput
                }

            case .local:
                #if targetEnvironment(macCatalyst)
                result = try await localExecutor!.executeStreaming(
                    command: command.command
                ) { [weak self] streamOutput in
                    self?.executingStreamOutput = streamOutput
                }
                #else
                result = try await iosLocalExecutor!.executeStreaming(
                    command: command.command
                ) { [weak self] streamOutput in
                    self?.executingStreamOutput = streamOutput
                }
                #endif
            }

            // Command completed - clear streaming output
            executingStreamOutput = nil
            state = .commandCompleted(command, output: result.output)

            // Add result to batch
            batchedToolResults.append(AIToolResult(
                toolCallId: command.toolCallId,
                output: result.output,
                isError: false,
                isFromXMLToolCall: command.isFromXMLToolCall
            ))

            // Process next pending call (or finalize if done)
            try processNextPendingToolCall(precedingText: nil)

        } catch {
            Self.logger.error("Command execution failed: \(error.localizedDescription)")

            // Clear streaming output on error
            executingStreamOutput = nil

            let errorMessage = error.localizedDescription
            state = .commandFailed(command, error: errorMessage)

            // Add error to batch
            batchedToolResults.append(AIToolResult(
                toolCallId: command.toolCallId,
                output: "Error: \(errorMessage)",
                isError: true,
                isFromXMLToolCall: command.isFromXMLToolCall
            ))

            // Continue with next pending call (or finalize if done)
            try? processNextPendingToolCall(precedingText: nil)
        }
    }

    /// Reject a pending command
    /// - Parameter reason: Optional reason for rejection
    func rejectCommand(reason: String? = nil) async {
        guard case .awaitingApproval(let command) = state else {
            Self.logger.warning("No command awaiting approval")
            return
        }

        // Clear any pending file tool call
        pendingFileToolCall = nil

        Self.logger.info("Command rejected: \(command.command)")

        // Add rejection to batch
        let rejectionMessage = reason ?? "User rejected this command"
        batchedToolResults.append(AIToolResult(
            toolCallId: command.toolCallId,
            output: "Command rejected: \(rejectionMessage)",
            isError: true,
            isFromXMLToolCall: command.isFromXMLToolCall
        ))

        // Process next pending call (or finalize if done)
        try? processNextPendingToolCall(precedingText: nil)
    }

    /// Edit a pending command
    /// - Parameter newCommand: The modified command
    func editCommand(_ newCommand: String) async {
        guard case .awaitingApproval(var command) = state else {
            Self.logger.warning("No command awaiting approval")
            return
        }

        Self.logger.info("Command edited: \(command.command) -> \(newCommand)")

        // Update the command (creates new with same ID)
        command.command = newCommand

        // Re-analyze risk (analysis is performed during AIAgentCommand init)
        let updatedCommand = AIAgentCommand(
            id: command.id,
            toolCallId: command.toolCallId,
            command: newCommand,
            explanation: command.explanation,
            timestamp: command.timestamp,
            isFromXMLToolCall: command.isFromXMLToolCall
        )

        // Update state with edited command
        state = .awaitingApproval(updatedCommand)
    }

    // MARK: - Question Answering

    /// Submit an answer to a pending question
    func submitAnswer(_ answerValue: AIAgentAnswer.Value) async {
        guard case .awaitingAnswer(let question) = state else {
            Self.logger.warning("No question awaiting answer")
            return
        }

        let answer = AIAgentAnswer(
            questionId: question.id,
            toolCallId: question.toolCallId,
            value: answerValue
        )

        Self.logger.info("Answer submitted for question: \(question.question)")

        // Add answer to batch
        batchedToolResults.append(AIToolResult(
            toolCallId: answer.toolCallId,
            output: answer.value.toResultString(),
            isError: false,
            isFromXMLToolCall: question.isFromXMLToolCall
        ))

        // Process next pending call (or finalize if done)
        try? processNextPendingToolCall(precedingText: nil)
    }

    /// Skip/cancel a pending question
    func skipQuestion() async {
        guard case .awaitingAnswer(let question) = state else {
            Self.logger.warning("No question awaiting answer")
            return
        }

        Self.logger.info("Question skipped: \(question.question)")

        // Add skip to batch
        batchedToolResults.append(AIToolResult(
            toolCallId: question.toolCallId,
            output: "User skipped this question",
            isError: true,
            isFromXMLToolCall: question.isFromXMLToolCall
        ))

        // Process next pending call (or finalize if done)
        try? processNextPendingToolCall(precedingText: nil)
    }

    /// Cancel current operation
    func cancel() {
        provider?.cancel()
        executor?.cancel()
        #if targetEnvironment(macCatalyst)
        localExecutor?.cancel()
        #else
        iosLocalExecutor?.cancel()
        #endif
        streamTask?.cancel()
        streamTask = nil

        // Clear streaming state to stop UI updates immediately
        isStreaming = false
        streamingText = nil
        streamingThinking = nil

        // A cancelled turn leaves the conversation in a state that no longer matches the last
        // measured prompt size, so drop the sample until the next successful response.
        lastPromptTokens = 0

        if state.isBusy {
            state = .idle
        }
    }

    /// Cancel the currently executing command and return to idle
    func cancelExecution() {
        guard case .executing(let command) = state else {
            Self.logger.warning("No command executing to cancel")
            return
        }

        Self.logger.info("Cancelling command execution: \(command.command)")

        // Cancel the executor task
        executor?.cancel()

        // Clear streaming output and reset state
        executingStreamOutput = nil
        state = .idle

        // Clear any pending tool calls since we're aborting the batch
        pendingToolCalls.removeAll()
        batchedToolResults.removeAll()
    }

    /// Clear conversation history
    func clearHistory() {
        messages.removeAll()
        conversationSystemPrompt = nil
        conversationTools = nil
        state = .idle
        totalTokensUsed = 0
        lastPromptTokens = 0
    }

    /// Reset to a new chat session while keeping the connection
    /// Clears messages, resets state, and optionally refreshes host info
    func resetToNewChat() async {
        Self.logger.info("Resetting AI Agent to new chat")

        // Cancel any pending operations
        cancel()

        // Clear conversation history
        messages.removeAll()
        conversationSystemPrompt = nil
        conversationTools = nil
        pendingFileToolCall = nil
        state = .idle
        totalTokensUsed = 0
        lastPromptTokens = 0

        // Refresh working directory from the terminal's current state
        if let cwdProvider = workingDirectoryProvider {
            let newCWD = cwdProvider()
            if let cwd = newCWD, cwd != initialWorkingDirectory {
                Self.logger.info("Updated working directory: \(cwd)")
                initialWorkingDirectory = cwd

                // Reconfigure the iOS executor with the new CWD
                #if !targetEnvironment(macCatalyst)
                if let iosLocal = iosLocalExecutor {
                    await iosLocal.disconnect()
                    let fresh = IOSLocalExecutor()
                    try? await fresh.connect(workingDirectory: cwd)
                    iosLocalExecutor = fresh
                }
                #endif
            }
        }

        // Refresh the fingerprint for fresh context
        await collectFingerprint(forceRefresh: true)
    }

    /// Update the selected model (creates a new provider instance)
    func updateModel(modelID: String) {
        guard isConnected else { return }

        // Drop the last prompt-size sample when the model actually changes — that sample was measured
        // against a different model's tokenizer/window and shouldn't be attributed to the new one.
        if modelID != currentModelID {
            lastPromptTokens = 0
        }

        // Save the new model selection to global storage
        AICredentialsManager.shared.globalSelectedModelID = modelID

        // Recreate the provider with the new model (routing to correct endpoint)
        if let newProvider = createProviderForModel(modelID) {
            provider = newProvider
            Self.logger.info("Updated AI model to: \(modelID)")
        }
    }

    /// Get the currently selected model ID
    var currentModelID: String {
        AICredentialsManager.shared.globalSelectedModelID
    }

    /// Rebuild the provider from the current credential state. Invoked when
    /// `AICredentialsManager` posts `.aiCredentialsChanged` — covers API key
    /// edits, custom provider renames/endpoint changes, and custom model
    /// ID edits. If the selection becomes invalid (e.g. its provider was
    /// deleted), `validatedSelectedModelID` auto-corrects to a surviving model.
    /// If no valid configuration remains at all, we fail closed by clearing
    /// the cached provider so subsequent `sendMessage` calls surface a
    /// configuration error instead of silently reusing now-deleted credentials
    /// from the in-memory provider object.
    private func reloadProviderFromCurrentSelection() {
        guard isConnected else { return }

        let previousModelID = currentModelID
        let modelID = AICredentialsManager.shared.validatedSelectedModelID

        if !modelID.isEmpty, let newProvider = createProviderForModel(modelID) {
            if modelID != previousModelID {
                lastPromptTokens = 0
            }
            // Do NOT cancel the old provider — an in-flight stream holds it by
            // value in sendMessageWithStreaming and must be allowed to finish.
            // The swap here only affects the next sendMessage call; the old
            // instance deallocs naturally once the stream completes.
            provider = newProvider
            Self.logger.info("Reloaded AI provider after credentials change (model: \(modelID))")
        } else {
            // No viable provider remains (e.g. last configured API key was
            // deleted). Cancel any in-flight stream, drop the stale provider,
            // and mark the session as unconfigured.
            provider?.cancel()
            streamTask?.cancel()
            streamTask = nil
            provider = nil
            isStreaming = false
            state = .error(.configuration("AI provider is not configured"))
            Self.logger.warning("Cleared AI provider — no valid model selection remains")
        }
    }

    /// Create the appropriate provider for a model ID
    /// Delegates to AICredentialsManager's shared factory.
    private func createProviderForModel(_ modelID: String) -> (any AIProvider)? {
        AICredentialsManager.shared.createProvider(forModelID: modelID)
    }

    // MARK: - Private Helpers

    private func processResponse(_ response: AIProviderResponse, thinking: AIThinkingBlock?, blocks: [AIAssistantBlock]?) async throws {
        Self.logger.debug("Processing response: \(String(describing: response.content))")

        switch response.content {
        case .text(let text):
            Self.logger.debug("Response is text only (\(text.count) chars), thinking: \(thinking?.content.count ?? 0) chars")
            // Store text with structured thinking (preserves signature for API round-trip)
            messages.append(.assistant(text, thinking: thinking, blocks: blocks))
            state = .idle

        case .toolCalls(let calls):
            Self.logger.debug("Response has \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            try await handleToolCalls(calls, precedingText: nil, thinking: thinking, blocks: blocks)

        case .textAndToolCalls(let text, let calls):
            Self.logger.debug("Response has text (\(text.count) chars) + \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            // DO NOT store text as a separate message when there are tool calls!
            // That would create two consecutive assistant messages, which violates the API.
            // The tool calls message (added by handleToolCalls) represents this assistant turn.
            // Store original text for API round-trips - UI filtering happens in displayText
            try await handleToolCalls(calls, precedingText: text, thinking: thinking, blocks: blocks)
        }
    }

    private func handleToolCalls(_ calls: [AIToolCall], precedingText: String?, thinking: AIThinkingBlock?, blocks: [AIAssistantBlock]?) async throws {
        Self.logger.debug("Handling \(calls.count) tool calls")
        for call in calls {
            Self.logger.debug("  - Tool: \(call.name), ID: \(call.id), Args: \(call.arguments.prefix(200))")
        }

        // Add tool calls to messages for history (include preceding text and thinking for UI display and API round-trip)
        messages.append(.assistantToolCalls(calls, precedingText: precedingText, thinking: thinking, blocks: blocks))

        // Initialize batch tracking - store all calls as pending
        pendingToolCalls = calls
        batchedToolResults = []

        // Process first tool call (UI handles one at a time)
        try processNextPendingToolCall(precedingText: precedingText)
    }

    /// Process the next pending tool call, or finalize batch if all done
    private func processNextPendingToolCall(precedingText: String?) throws {
        guard !pendingToolCalls.isEmpty else {
            // All calls processed - finalize batch and continue conversation
            finalizeBatchedToolResults()
            return
        }

        let nextCall = pendingToolCalls.removeFirst()
        let remainingCount = pendingToolCalls.count
        Self.logger.debug("Processing tool call \(nextCall.name) (\(remainingCount) remaining)")

        // Models occasionally change a tool name's case; accept an unambiguous match.
        let tools = conversationTools ?? availableTools
        let toolName = tools.first { $0.name.caseInsensitiveCompare(nextCall.name) == .orderedSame }?.name ?? nextCall.name

        // The tool list stays frozen for replay, so a setting turned off mid-conversation is
        // enforced here instead.
        if (toolName == "web_search" || toolName == "web_fetch") && !AICredentialsManager.shared.webSearchEnabled {
            batchedToolResults.append(AIToolResult(
                toolCallId: nextCall.id,
                output: "Error: Web search is turned off in Settings.",
                isError: true,
                isFromXMLToolCall: nextCall.isFromXMLParsing
            ))
            try processNextPendingToolCall(precedingText: nil)
            return
        }

        switch toolName {
        case "ask_user":
            try handleAskUserCall(nextCall, precedingText: precedingText)

        case "execute_command":
            try handleExecuteCommandCall(nextCall, precedingText: precedingText)

        case "read_file":
            handleReadFileCall(nextCall)

        case "write_file":
            handleWriteFileCall(nextCall, precedingText: precedingText)

        case "edit_file":
            handleEditFileCall(nextCall, precedingText: precedingText)

        case "web_search":
            Task { await handleWebSearchCall(nextCall) }

        case "web_fetch":
            Task { await handleWebFetchCall(nextCall) }

        default:
            // Unknown tool - add error result and continue to next
            Self.logger.warning("Unknown tool call: \(nextCall.name)")
            batchedToolResults.append(AIToolResult(
                toolCallId: nextCall.id,
                output: "Error: Unknown tool '\(nextCall.name)'. Available tools: \(tools.map(\.name).joined(separator: ", "))",
                isError: true,
                isFromXMLToolCall: nextCall.isFromXMLParsing
            ))
            try processNextPendingToolCall(precedingText: nil)
        }
    }

    /// Called when all tool calls in batch have been processed
    /// Sends batched results to the API and continues conversation
    private func finalizeBatchedToolResults() {
        guard !batchedToolResults.isEmpty else {
            Self.logger.debug("No batched results to finalize")
            state = .idle
            return
        }

        let batchCount = batchedToolResults.count
        Self.logger.info("Finalizing batch with \(batchCount) tool results")

        // Add all results as a single batched message
        messages.append(.toolResults(batchedToolResults))

        // Clear batch state
        batchedToolResults = []
        pendingToolCalls = []

        // Continue conversation with all results
        Task {
            guard let provider = provider else {
                state = .idle
                return
            }

            state = .thinking
            await sendMessageWithStreaming(provider: provider)
        }
    }

    private func handleAskUserCall(_ call: AIToolCall, precedingText: String?) throws {
        guard let questionText: String = call.argument("question"),
              let inputTypeString: String = call.argument("input_type"),
              let inputType = AIAgentQuestion.InputType(rawValue: inputTypeString) else {
            state = .error(.unknown("Invalid question format from AI"))
            return
        }

        // Parse optional parameters
        let options: [String] = call.argument("options") ?? []
        let placeholder: String? = call.argument("placeholder")
        let context: String? = call.argument("context")

        // Validate options for choice types
        if (inputType == .singleChoice || inputType == .multiChoice) && options.isEmpty {
            state = .error(.unknown("AI asked a choice question without providing options"))
            return
        }

        let question = AIAgentQuestion(
            toolCallId: call.id,
            question: questionText,
            inputType: inputType,
            options: options,
            placeholder: placeholder,
            context: context,
            isFromXMLToolCall: call.isFromXMLParsing
        )

        // Move to awaiting answer state
        state = .awaitingAnswer(question)

        Self.logger.info("Question asked: \(questionText) (type: \(inputType.rawValue))")
    }

    private func handleExecuteCommandCall(_ call: AIToolCall, precedingText: String?) throws {
        guard let commandString: String = call.argument("command") else {
            state = .error(.unknown("Invalid command format from AI"))
            return
        }

        // Parse new optional parameters
        let reason: String? = call.argument("reason")
        let declaredTypeString: String? = call.argument("operation_type")
        let declaredType = declaredTypeString.flatMap { AIAgentCommand.OperationType(rawValue: $0) }

        // Filter thinking/tool tags from explanation text (UI display only - API uses original)
        // Apply three-layer stripping: thinking → minimax → text tool markers
        let explanation: String?
        if let text = precedingText {
            let thinkingParsed = ThinkingParser.parse(text)
            let minimaxFiltered = MiniMaxToolCallParser.parse(thinkingParsed.text).remainingText
            let fullyFiltered = TextToolCallParser.parse(minimaxFiltered).remainingText
            explanation = fullyFiltered.isEmpty ? nil : fullyFiltered
        } else {
            explanation = nil
        }

        // Create command with risk analysis and operation type detection
        let command = AIAgentCommand(
            toolCallId: call.id,
            command: commandString,
            explanation: explanation,
            reason: reason,
            declaredOperationType: declaredType,
            isFromXMLToolCall: call.isFromXMLParsing
        )

        Self.logger.info("Command proposed: \(commandString) (risk: \(command.riskLevel.displayName), op: \(command.effectiveOperationType.rawValue), misclassified: \(command.isMisclassified))")

        // Determine if approval is needed based on mode
        if shouldAutoApproveCommand(command) {
            Self.logger.info("Auto-approving command (mode: \(AICredentialsManager.shared.approvalMode.rawValue))")
            Task { await executeCommand(command) }
            return
        }

        // Show approval UI
        state = .awaitingApproval(command)
    }

    /// Determines if a command should be auto-approved based on current mode
    private func shouldAutoApproveCommand(_ command: AIAgentCommand) -> Bool {
        let mode = AICredentialsManager.shared.approvalMode

        switch mode {
        case .askAll:
            return false

        case .approveWritesOnly:
            // Only auto-approve if it's a read AND not misclassified
            return command.effectiveOperationType == .read && !command.isMisclassified

        case .yolo:
            return true
        }
    }

    // MARK: - File Tool Handlers

    /// Working directory for file tools (uses terminal CWD if available, falls back to Documents)
    private var fileToolWorkingDirectory: String {
        initialWorkingDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    private func handleReadFileCall(_ call: AIToolCall) {
        guard let path: String = call.argument("path"), !path.isEmpty else {
            Self.logger.error("read_file missing required 'path' parameter")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: "Error: Missing required 'path' parameter",
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
            return
        }

        let offset: Int? = call.argument("offset")
        let limit: Int? = call.argument("limit")

        // read_file is a read operation — create synthetic command for approval check
        let syntheticCommand = AIAgentCommand(
            toolCallId: call.id,
            command: "read_file: \(path)",
            explanation: nil,
            reason: nil,
            declaredOperationType: .read,
            isFromXMLToolCall: call.isFromXMLParsing
        )

        if shouldAutoApproveCommand(syntheticCommand) {
            // Auto-execute read
            let result = AIAgentFileToolHandler.readFile(
                path: path,
                offset: offset,
                limit: limit,
                workingDirectory: fileToolWorkingDirectory
            )
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: result.output,
                isError: result.exitCode != 0,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
        } else {
            // Show approval UI for read
            state = .awaitingApproval(syntheticCommand)
            // Store the file tool context for execution after approval
            pendingFileToolCall = (call, "read_file")
        }
    }

    private func handleWriteFileCall(_ call: AIToolCall, precedingText: String?) {
        guard let path: String = call.argument("path"), !path.isEmpty,
              let content: String = call.argument("content") else {
            Self.logger.error("write_file missing required parameters")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: "Error: Missing required 'path' or 'content' parameter",
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
            return
        }

        // Filter explanation text
        let explanation: String?
        if let text = precedingText {
            let thinkingParsed = ThinkingParser.parse(text)
            let minimaxFiltered = MiniMaxToolCallParser.parse(thinkingParsed.text).remainingText
            let fullyFiltered = TextToolCallParser.parse(minimaxFiltered).remainingText
            explanation = fullyFiltered.isEmpty ? nil : fullyFiltered
        } else {
            explanation = nil
        }

        let lineCount = content.components(separatedBy: "\n").count
        let syntheticCommand = AIAgentCommand(
            toolCallId: call.id,
            command: "write_file: \(path) (\(lineCount) lines)",
            explanation: explanation,
            reason: nil,
            declaredOperationType: .write,
            isFromXMLToolCall: call.isFromXMLParsing
        )

        if shouldAutoApproveCommand(syntheticCommand) {
            let result = AIAgentFileToolHandler.writeFile(
                path: path,
                content: content,
                workingDirectory: fileToolWorkingDirectory
            )
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: result.output,
                isError: result.exitCode != 0,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
        } else {
            state = .awaitingApproval(syntheticCommand)
            pendingFileToolCall = (call, "write_file")
        }
    }

    private func handleEditFileCall(_ call: AIToolCall, precedingText: String?) {
        guard let path: String = call.argument("path"), !path.isEmpty,
              let oldString: String = call.argument("old_string"),
              let newString: String = call.argument("new_string") else {
            Self.logger.error("edit_file missing required parameters")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: "Error: Missing required 'path', 'old_string', or 'new_string' parameter",
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
            return
        }

        // Filter explanation text
        let explanation: String?
        if let text = precedingText {
            let thinkingParsed = ThinkingParser.parse(text)
            let minimaxFiltered = MiniMaxToolCallParser.parse(thinkingParsed.text).remainingText
            let fullyFiltered = TextToolCallParser.parse(minimaxFiltered).remainingText
            explanation = fullyFiltered.isEmpty ? nil : fullyFiltered
        } else {
            explanation = nil
        }

        let syntheticCommand = AIAgentCommand(
            toolCallId: call.id,
            command: "edit_file: \(path)",
            explanation: explanation,
            reason: nil,
            declaredOperationType: .write,
            isFromXMLToolCall: call.isFromXMLParsing
        )

        if shouldAutoApproveCommand(syntheticCommand) {
            let result = AIAgentFileToolHandler.editFile(
                path: path,
                oldString: oldString,
                newString: newString,
                workingDirectory: fileToolWorkingDirectory
            )
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: result.output,
                isError: result.exitCode != 0,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
        } else {
            state = .awaitingApproval(syntheticCommand)
            pendingFileToolCall = (call, "edit_file")
        }
    }

    /// Execute a pending file tool call after approval
    private func executeFileToolCommand(_ call: AIToolCall, toolName: String) {
        let result: CommandExecutionResult

        switch toolName {
        case "read_file":
            let path: String = call.argument("path") ?? ""
            let offset: Int? = call.argument("offset")
            let limit: Int? = call.argument("limit")
            result = AIAgentFileToolHandler.readFile(
                path: path, offset: offset, limit: limit,
                workingDirectory: fileToolWorkingDirectory
            )

        case "write_file":
            let path: String = call.argument("path") ?? ""
            let content: String = call.argument("content") ?? ""
            result = AIAgentFileToolHandler.writeFile(
                path: path, content: content,
                workingDirectory: fileToolWorkingDirectory
            )

        case "edit_file":
            let path: String = call.argument("path") ?? ""
            let oldString: String = call.argument("old_string") ?? ""
            let newString: String = call.argument("new_string") ?? ""
            result = AIAgentFileToolHandler.editFile(
                path: path, oldString: oldString, newString: newString,
                workingDirectory: fileToolWorkingDirectory
            )

        default:
            result = CommandExecutionResult(output: "Error: Unknown file tool '\(toolName)'", exitCode: 1, duration: 0)
        }

        // Brief executing state for visual feedback
        if case .awaitingApproval(let cmd) = state {
            state = .executing(cmd)
        }

        batchedToolResults.append(AIToolResult(
            toolCallId: call.id,
            output: result.output,
            isError: result.exitCode != 0,
            isFromXMLToolCall: call.isFromXMLParsing
        ))

        if case .executing(let cmd) = state {
            if result.exitCode == 0 {
                state = .commandCompleted(cmd, output: result.output)
            } else {
                state = .commandFailed(cmd, error: result.output)
            }
        }

        try? processNextPendingToolCall(precedingText: nil)
    }

    // MARK: - Web Tool Handlers

    private func handleWebSearchCall(_ call: AIToolCall) async {
        guard let query: String = call.argument("query"), !query.isEmpty else {
            Self.logger.error("web_search missing required 'query' parameter")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: "Error: Missing required 'query' parameter",
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
            return
        }

        // Parse optional parameters
        let maxResults: Int = call.argument("max_results") ?? 5
        let defaultEngine = AICredentialsManager.shared.defaultSearchEngine
        let engineString: String = call.argument("engine") ?? defaultEngine.rawValue
        let engine = SearchEngine(rawValue: engineString) ?? defaultEngine

        Self.logger.info("Executing web_search: '\(query)' via \(engine.displayName)")

        // Update state to show what we're doing
        state = .webSearching(query: query, engine: engine.displayName)

        do {
            let results = try await WebBrowserManager.shared.search(
                query: query,
                engine: engine,
                maxResults: min(maxResults, 10)
            )

            let formatted = WebSearchParser.formatSearchResults(
                results,
                query: query,
                engine: engine
            )

            Self.logger.info("web_search completed: \(results.count) results")

            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: formatted,
                isError: false,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
        } catch let error as WebBrowserError {
            Self.logger.error("web_search failed: \(error.localizedDescription)")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: WebSearchParser.formatError(error),
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
        } catch {
            Self.logger.error("web_search failed: \(error.localizedDescription)")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: "Error: \(error.localizedDescription)",
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
        }

        try? processNextPendingToolCall(precedingText: nil)
    }

    private func handleWebFetchCall(_ call: AIToolCall) async {
        guard let urlString: String = call.argument("url"), !urlString.isEmpty else {
            Self.logger.error("web_fetch missing required 'url' parameter")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: "Error: Missing required 'url' parameter",
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
            try? processNextPendingToolCall(precedingText: nil)
            return
        }

        // Parse optional parameters
        let extractLinks: Bool = call.argument("extract_links") ?? true

        Self.logger.info("Executing web_fetch: \(urlString)")

        // Update state to show what we're doing
        state = .webFetching(url: urlString)

        do {
            let content = try await WebBrowserManager.shared.fetch(
                urlString: urlString,
                extractLinks: extractLinks
            )

            let formatted = WebSearchParser.formatPageContent(
                content,
                includeLinks: extractLinks
            )

            Self.logger.info("web_fetch completed: \(content.contentLength) chars from \(content.url)")

            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: formatted,
                isError: false,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
        } catch let error as WebBrowserError {
            Self.logger.error("web_fetch failed: \(error.localizedDescription)")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: WebSearchParser.formatError(error),
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
        } catch {
            Self.logger.error("web_fetch failed: \(error.localizedDescription)")
            batchedToolResults.append(AIToolResult(
                toolCallId: call.id,
                output: "Error: \(error.localizedDescription)",
                isError: true,
                isFromXMLToolCall: call.isFromXMLParsing
            ))
        }

        try? processNextPendingToolCall(precedingText: nil)
    }

    private func handleError(_ error: Error) {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .cancelled:
                state = .idle
            default:
                state = .error(AIAgentErrorCategory.from(providerError))
            }
        } else {
            state = .error(AIAgentErrorCategory.from(error))
        }
    }

    // MARK: - Error Actions

    /// Retry the last failed message
    func retryLastMessage() async {
        guard case .error = state else { return }
        guard let provider = provider else {
            state = .error(.configuration("Not connected"))
            return
        }

        // Reset to thinking state and resend
        state = .thinking
        await sendMessageWithStreaming(provider: provider)
    }

    /// Dismiss error and return to idle
    func dismissError() {
        guard case .error = state else { return }
        state = .idle
    }

    /// Claude models that write progress notes between tool calls; the no-narration rules
    /// other models need would suppress them.
    private var modelWritesProgressUpdates: Bool {
        let modelID = currentModelID.hasPrefix("bedrock-") ? String(currentModelID.dropFirst(8)) : currentModelID
        return ["claude-fable-5", "claude-opus-5-5", "claude-sonnet-5-5"].contains { modelID.hasPrefix($0) }
    }

    /// Anthropic's suggested wording for keeping the user informed during long tool runs.
    private static let progressUpdateGuidance = """
        ## How to Respond
        - Before you start, say in a line what you're about to do; brief updates while you work help the user follow along.
        - Call tools to do the work rather than describing commands; explain results after you receive output.
        - Use ask_user only when you need information (a path, a choice, a clarification).
        - If you have more work to do, your response must contain a tool call.


        """

    private func buildSystemPrompt() -> String {
        // Catalyst has no ios_system local sessions, so the constrained
        // prompt only exists on iOS/iPadOS.
        #if !targetEnvironment(macCatalyst)
        if case .local = connectionType {
            return buildIOSLocalSystemPrompt()
        }
        #endif
        return buildSSHSystemPrompt()
    }

    /// Build system prompt for iOS local sessions (constrained ios_system environment)
    private func buildIOSLocalSystemPrompt() -> String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let cwdPath = initialWorkingDirectory ?? documentsPath

        var prompt = """
        You are a local file and development assistant running on an iOS device. You have access to a LIMITED set of Unix-like commands via ios_system — this is NOT a full shell.

        ## CRITICAL: Tool Use Requirements
        - You MUST call tools for ALL operations. NEVER output command text without a tool call.
        - When asked to do something, respond with a tool call immediately - not a description.
        - Do NOT ask "Should I run X?" - call the tool directly. The user approves via the UI.
        - If you write a command in backticks without a tool call, you have made a mistake.

        ## CRITICAL: Limited Command Set
        You can ONLY use these commands with execute_command. Any other command will fail:

        File Operations: ls, pwd, cd, cat, cp, mv, rm, ln, mkdir, rmdir, touch, find, du, stat, chmod, chown, chflags, readlink
        Text Processing: grep, egrep, fgrep, rg, sed, awk, wc, sort, uniq, diff, head, tail, tr, md5
        Archives: tar, gzip, gunzip, compress, uncompress
        Network: curl, nc, dig, host, nslookup, whois, ifconfig
        Developer: git, bat, jq, rg
        Shell Utils: echo, env, printenv, date, uname, whoami, tee, uptime, pbcopy, pbpaste
        Other: df, id, w, chgrp

        ## NOT AVAILABLE — Do NOT try these:
        - No bash/zsh/sh (no shell scripting, no $() subshells, no backticks)
        - No python, node, ruby, go, perl, or any language runtimes
        - No apt, brew, pip, npm, or package managers
        - No sudo, ps, kill, top, systemctl, docker, kubectl
        - No make, gcc, clang, or compilers
        - No wget (use curl instead)

        ## What Works:
        - Pipes work: cat file | grep pattern | sort
        - Redirects work: echo text > file, cat file >> other
        - Compound commands with && work: cd /path && ls -la
        - git operations work (libgit2-based, not standard git)

        ## File Tools (Preferred for File Operations)
        You have direct file access tools. PREFER these over shell commands for file content:
        - **read_file**: Read file contents with line numbers (supports offset/limit for large files)
          - `path` (required): File path relative to working directory or absolute
          - `offset` (optional): Line number to start from (1-indexed)
          - `limit` (optional): Maximum lines to read
        - **write_file**: Create or overwrite a file (creates parent directories)
          - `path` (required): File path
          - `content` (required): Full file content
        - **edit_file**: Find-and-replace edit (old_string must match exactly including whitespace)
          - `path` (required): File path
          - `old_string` (required): Exact string to find
          - `new_string` (required): Replacement string

        ### When to Use Which:
        - Use **file tools** for: reading file contents, creating files, making targeted edits
        - Use **execute_command** for: ls, find, grep/rg, git, jq, curl, and other available commands

        """

        // Add host information
        if let fp = fingerprint {
            prompt += """
            ## Device Information
            \(fp.summary())

            """
        } else {
            prompt += """
            ## Device Information
            - Platform: iOS
            - Shell: ios_system (limited command set)

            """
        }

        // Add date/time
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let currentDateTime = dateFormatter.string(from: Date())
        let timeZone = TimeZone.current.identifier

        prompt += """
        ## Current Date and Time (USE THIS AS YOUR REFERENCE)
        - Local time: \(currentDateTime)
        - Time zone: \(timeZone)
        Do NOT rely on your training data for the current date.

        ## execute_command Parameters
        When calling execute_command, provide:
        - `command` (required): The command to execute (must be from the available command list above)
        - `reason` (encouraged): Brief explanation of why this command is needed
        - `operation_type` (encouraged): Declare "read" or "write"

        ## Command Execution Model
        Each execute_command call runs independently. There is NO persistent state between commands.
        - Working directory starts at: \(cwdPath)
        - Environment variables don't persist between calls
        - Chain related commands: `cd /path && ls -la`

        ## Environment
        - Current working directory: \(cwdPath)
        - Home directory: \(documentsPath) (iOS sandbox)
        - All files are in the app's Documents directory or bookmarked external locations
        - No access to system files or other app containers


        """

        prompt += modelWritesProgressUpdates ? Self.progressUpdateGuidance : """
        ## How to Respond
        - Call tools IMMEDIATELY when you need to do something
        - Do NOT narrate before tool calls. JUST CALL THE TOOL
        - You MAY explain results AFTER receiving output
        - Use ask_user ONLY when you need information

        ## CRITICAL: No Text Without Tool Calls
        If you have more work to do, your response MUST contain a tool call.

        """

        // Web search docs if enabled
        if AICredentialsManager.shared.webSearchEnabled {
            let defaultEngine = AICredentialsManager.shared.defaultSearchEngine
            let otherEngine = defaultEngine == .duckduckgo ? "google" : "duckduckgo"
            prompt += """

        ## web_search Tool
        Search the internet for information.
        - `query` (required): The search query
        - `engine` (optional): '\(defaultEngine.rawValue)' (default) or '\(otherEngine)'
        - `max_results` (optional): 1-10, default 5

        ## web_fetch Tool
        Fetch and read web page content:
        - `url` (required): The complete URL to fetch
        - `extract_links` (optional): Whether to include links (default true)

        """
        }

        prompt += """
        ## Safety
        - Commands are risk-analyzed and require user approval before execution
        - For dangerous operations (rm -rf, etc.), warn in your explanation

        ## Non-Interactive Execution
        This session cannot provide interactive input. Commands that prompt for input will fail.
        - Text editors (vim, nano) won't work — use file tools (write_file, edit_file) instead
        - Pagers (less, more) won't work — pipe to `cat` or use `head`/`tail`
        - Git pager: use `git --no-pager` or `GIT_PAGER=cat`

        ## MANDATORY: Task Completion Summary
        When you have completed the user's request, provide a clear summary including:
        1. What was accomplished
        2. Key results
        3. Relevant file paths or changes
        4. Next steps (if applicable)

        REMEMBER: The user may not see raw command output. Your summary is their confirmation that the task is complete.
        """

        return prompt
    }

    /// Build system prompt for SSH and Mac Catalyst local sessions
    private func buildSSHSystemPrompt() -> String {
        var prompt = """
        You are a server management assistant. Your PRIMARY job is to execute commands using the execute_command tool - not to describe commands.

        ## CRITICAL: Tool Use Requirements
        - You MUST call execute_command for ALL commands. NEVER output command text without a tool call.
        - When asked to do something, respond with a tool call immediately - not a description.
        - Do NOT ask "Should I run X?" - call execute_command directly. The user approves via the UI.
        - If you write a command in backticks without a tool call, you have made a mistake.

        """

        // Add host information if available
        if let fp = fingerprint {
            prompt += """
            ## Host Information
            \(fp.summary())

            ## Available Tools
            \(fp.toolsSummary())

            ## Environment
            \(fp.environmentSummary())

            """
        } else if let sshConfig = sshConfig {
            prompt += """
            ## Host Information
            - Host: \(sshConfig.host)
            - User: \(sshConfig.username)

            """
        } else {
            prompt += """
            ## Host Information
            - Host: localhost (Mac Catalyst)
            - Connection: Local shell

            """
        }

        // Add current date and time for context
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let currentDateTime = dateFormatter.string(from: Date())

        let timeZone = TimeZone.current.identifier

        prompt += """
        ## Current Date and Time (USE THIS AS YOUR REFERENCE)
        - Local time: \(currentDateTime)
        - Time zone: \(timeZone)

        IMPORTANT: This is the ACTUAL current date and time for this session. Use this to ground ALL your reasoning about time:
        - When interpreting log timestamps, cron schedules, or file dates
        - When the user asks "today", "yesterday", "this week", etc.
        - When calculating relative times or checking if something is recent
        - When suggesting time-based commands or filters
        Do NOT rely on your training data for the current date. The time above is authoritative.

        ## execute_command Parameters
        When calling execute_command, provide:
        - `command` (required): The shell command to execute
        - `reason` (encouraged): Brief explanation of why this command is needed
        - `operation_type` (encouraged): Declare "read" or "write"
          - "read": Commands that only inspect/view (ls, cat, grep, ps, df, find, head, tail, stat, netstat, systemctl status, git log, docker ps, kubectl get)
          - "write": Commands that modify state (rm, mv, cp, mkdir, chmod, chown, apt install, systemctl start/stop/restart, kill, git commit, docker run, kubectl apply)
        - If unsure about operation_type, use "write". Misclassifying a write as read triggers a safety warning.

        ## Command Execution Model
        Each execute_command call runs in a FRESH login shell. There is NO persistent state between commands.

        ### What This Means:
        - **Working directory resets**: Each command starts in the user's home directory (~), NOT where the previous command left off
        - **Environment variables don't persist**: `export VAR=value` won't carry to the next command
        - **Shell state is isolated**: Variables, aliases, and functions from previous commands are lost

        ### WRONG (will not work as expected):
        1. execute_command: `cd /var/log`
        2. execute_command: `ls -la`  ← This runs in ~, NOT /var/log!

        3. execute_command: `export DEBUG=1`
        4. execute_command: `./my-script.sh`  ← DEBUG is NOT set here!

        ### CORRECT (use compound commands):
        1. execute_command: `cd /var/log && ls -la`  ← Both run in /var/log
        2. execute_command: `DEBUG=1 ./my-script.sh`  ← Inline env var

        ### Best Practices:
        - Chain related commands with `&&`: `cd /app && npm install && npm run build`
        - Set env vars inline: `DEBIAN_FRONTEND=noninteractive apt-get install -y nginx`
        - For complex multi-step operations, combine into a single compound command
        - If you need to reference a path multiple times, use the full absolute path each time


"""

        prompt += modelWritesProgressUpdates ? Self.progressUpdateGuidance : """
        ## How to Respond
        - Call execute_command IMMEDIATELY when you need to run a command
        - Do NOT narrate before tool calls. No "Let me...", "I'll...", "I need to..." - JUST CALL THE TOOL
        - You MAY explain results AFTER receiving command output
        - Use ask_user ONLY when you need information (path, choice, clarification)

        ## CRITICAL: No Text Without Tool Calls
        If you have more work to do, your response MUST contain a tool call.
        Do NOT output "Let me..." or "I'll..." without a tool call in the SAME response.
        Thinking out loud is NOT doing work. Tool calls are doing work.

        ## WRONG (do not do these)
        - "I'll run `ls -la` to check" then stopping without tool call
        - "Let me examine the logs" then stopping ← THIS IS WRONG, call the tool!
        - "Would you like me to execute...?" - just call the tool
        - "Here's a command: `apt update`" - use execute_command instead

        ## CORRECT (do these)
        - User asks "what's in this directory?" → [call execute_command: ls -la] (no narration needed)
        - After command output → "The directory contains 5 files..." (explanation is OK here)
        - Need another command? → [call execute_command: ...] (don't say "Let me...", just call it)


"""

        prompt += """
        ## ask_user Tool
        Use ONLY when you need information:
        - `yes_no`: Simple binary choice
        - `single_choice`: Pick one option
        - `multi_choice`: Pick multiple options
        - `text`: Need a path, name, or value

"""

        // Only include web search documentation if enabled
        if AICredentialsManager.shared.webSearchEnabled {
            let defaultEngine = AICredentialsManager.shared.defaultSearchEngine
            let otherEngine = defaultEngine == .duckduckgo ? "google" : "duckduckgo"
            prompt += """

        ## web_search Tool
        Search the internet for information. Use this to:
        - Look up documentation, tutorials, or error messages
        - Find solutions to problems you don't know how to solve
        - Research best practices or configuration options
        Parameters:
        - `query` (required): The search query. Be specific.
        - `engine` (optional): '\(defaultEngine.rawValue)' (default) or '\(otherEngine)'
        - `max_results` (optional): 1-10, default 5

        ## web_fetch Tool
        Fetch and read the content of a web page. Use after web_search to read full articles:
        - `url` (required): The complete URL to fetch
        - `extract_links` (optional): Whether to include links (default true)

        """
        }

        prompt += """
        ## Safety
        - Commands are risk-analyzed and require user approval before execution
        - Risk levels: Low (read-only), Medium (modifies state), High (significant), Critical (destructive)
        - For dangerous operations (rm -rf, dd, etc.), warn in your explanation after calling the tool

        ## Non-Interactive Command Execution
        This session cannot provide interactive input. Commands that prompt for input will hang or fail.

        ### Package Managers - ALWAYS Use Non-Interactive Flags
        - apt/apt-get: MUST use `DEBIAN_FRONTEND=noninteractive apt-get install -y <package>` - the -y flag alone is NOT sufficient, DEBIAN_FRONTEND is REQUIRED to prevent dpkg configuration prompts
        - yum/dnf: `yum install -y <package>` or `dnf install -y <package>`
        - pacman: `pacman -S --noconfirm <package>`
        - zypper: `zypper --non-interactive install <package>`
        - apk: Generally non-interactive, use `-q` for quieter output

        ### Commands to AVOID (require interactive input)
        - Text editors: vim, nano, emacs, vi → use echo, cat, sed, or tee for file edits
        - Interactive prompts: passwd → use `chpasswd`, adduser → use `useradd`
        - Pagers: less, more → pipe to `cat` or use `head`/`tail` instead

        ### Preventing Pager Invocation
        - Git: `git --no-pager log` or prefix with `GIT_PAGER=cat`
        - General: Append `| cat` or prefix command with `PAGER=cat`

        ### Other Non-Interactive Considerations
        - sudo: Assumes passwordless sudo is configured for this user
        - Confirmations: Always use -y, --yes, --force, or --noconfirm flags where available
        - SSH: Avoid nested SSH connections; if absolutely needed use `-o BatchMode=yes -o StrictHostKeyChecking=no`

        ## MANDATORY: Task Completion Summary
        When you have completed the user's request, you MUST provide a clear summary. DO NOT just stop responding.

        Your completion summary MUST include:
        1. **What was accomplished**: Brief recap of actions taken
        2. **Key results**: Important findings, changes made, or outcomes
        3. **Relevant details**: File paths modified, services affected, configuration changes
        4. **Next steps** (if applicable): Recommendations, follow-up actions, or things to monitor

        ### Examples of CORRECT completion behavior:
        ✅ "Done. I've restarted nginx and verified it's running on port 80. The config syntax check passed. Monitor `/var/log/nginx/error.log` for any issues."
        ✅ "Task complete. Created user 'deploy' with SSH key access. Home directory: /home/deploy. Added to sudo group. Test login before removing your current session."
        ✅ "Finished. Found 3 large log files consuming 4.2GB total. Rotated and compressed them. Freed 3.8GB on /var. Consider setting up logrotate."

        ### Examples of WRONG behavior (DO NOT DO THIS):
        ❌ Executing a final command and then producing no text response
        ❌ Saying "Let me know if you need anything else" without summarizing what was done
        ❌ Stopping after showing command output without explaining the outcome
        ❌ Trailing off with "The command completed successfully." without context

        REMEMBER: The user may not see raw command output. Your summary is their confirmation that the task is complete and successful.
        """

        return prompt
    }
}

// MARK: - Session Errors

/// Errors specific to AI Agent sessions
enum AIAgentSessionError: LocalizedError, Sendable {
    case notConfigured
    case connectionFailed
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI provider configured. Please configure an AI provider in Settings."
        case .connectionFailed:
            return "Failed to establish SSH connection"
        case .sessionExpired:
            return "Session has expired"
        }
    }
}
#endif
