#if !CHINA_BUILD
//
//  AIAgentOverlayView.swift
//  rootshell
//
//  Full-screen overlay container for AI Agent
//

import SwiftUI
import UIKit

/// Cached model data to avoid repeated observable property access.
///
/// Equatable so the toolbar subviews can short-circuit body re-evaluation
/// when the parent re-renders on streaming ticks. The previous tuple-typed
/// `customProviders` blocked Equatable conformance — Swift tuples can't
/// participate in protocols.
private struct CachedCustomProvider: Equatable {
    let name: String
    let models: [AIProviderModel]
}

/// The effort-switcher inputs for the selected ChatGPT model.
private struct ChatGPTEffortContext: Equatable {
    let modelID: String
    let ladder: [ChatGPTReasoningEffort]
    let defaultEffort: ChatGPTReasoningEffort
}

private struct CachedModelData: Equatable {
    var hasOpenAI = false
    var hasChatGPT = false
    var hasAnthropic = false
    var hasBedrock = false
    var hasGoogle = false
    var hasOpenRouter = false
    var chatgptModels: [AIProviderModel] = []
    /// Discovery records carrying each ChatGPT model's effort ladder + default.
    var chatgptReasoning: [CachedChatGPTModel] = []
    var openRouterModels: [AIProviderModel] = []
    var customProviders: [CachedCustomProvider] = []
    var displayNames: [String: String] = [:]
}

/// AI Agent interface view
struct AIAgentOverlayView: View {
    @Environment(\.edgeSidebarTitleContext) private var edgeSidebarTitleContext
    @Environment(\.sheetThemeColors) private var sidebarThemeColors
    @Binding var isPresented: Bool
    var session: AIAgentSession
    let showCloseButton: Bool
    let useWindowThemeColors: Bool
    let tabID: UUID

    var effectManager = EffectManager.shared
    var themeManager = ThemeManager.shared

    @State private var inputText = ""
    @State private var showSettings = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedModelID: String
    @State private var approvalMode: CommandApprovalMode
    @State private var cachedModels = CachedModelData()
    @State private var scrollToBottomTrigger = false
    @State private var availableWidth: CGFloat = 0
    /// The stored per-model reasoning override (nil = model default). Only
    /// meaningful while a ChatGPT model is selected.
    @State private var selectedEffort: ChatGPTReasoningEffort?

    @FocusState private var isInputFocused: Bool

    init(
        isPresented: Binding<Bool>,
        session: AIAgentSession,
        tabID: UUID,
        showCloseButton: Bool = true,
        useWindowThemeColors: Bool = false
    ) {
        self._isPresented = isPresented
        self.session = session
        self.tabID = tabID
        self.showCloseButton = showCloseButton
        self.useWindowThemeColors = useWindowThemeColors
        // Initialize with validated model selection (ensures model exists in available providers)
        self._selectedModelID = State(initialValue: AICredentialsManager.shared.validatedSelectedModelID)
        // Initialize approval mode from stored setting
        self._approvalMode = State(initialValue: AICredentialsManager.shared.approvalMode)
    }

    // Toggle/dismiss shortcut read live from KeybindManager (default Cmd-I) so a
    // remapped toggle_ai_agent is honored instead of a hardcoded chord.
    private var aiToggleKeys: Set<KeyEquivalent> {
        guard let key = KeybindManager.shared.keybind(for: .toggle_ai_agent)?.sequence.first?.swiftUIKeyEquivalent
        else { return [] }
        return [key]
    }
    private var aiToggleModifiers: EventModifiers {
        KeybindManager.shared.keybind(for: .toggle_ai_agent)?.sequence.first?.swiftUIEventModifiers ?? [.command]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let context = edgeSidebarTitleContext {
                    EdgeSidebarHeader(
                        title: context.selection.title,
                        systemImage: context.selection.systemImage,
                        showsClose: showCloseButton,
                        onClose: dismiss
                    ) {
                        if shouldShowNewChatButton {
                            newChatButton.edgeSidebarHeaderActionTarget()
                        }
                        overflowMenu.edgeSidebarHeaderActionTarget()
                    }

                    if session.isConnected {
                        modelPickerAndEffortControls
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                }

                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        if !session.isConnected {
                            connectionStatusBar
                        }

                        if session.isConnected {
                            AIAgentChatView(session: session, scrollToBottomTrigger: $scrollToBottomTrigger)
                        } else {
                            connectingView
                        }

                        if session.isConnected {
                            inputArea
                        }

                        Button("") {
                            dismiss()
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                        .opacity(0)
                        .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Keyboard avoidance only uses the terminal keyboard height while this composer owns focus.
                    .padding(.bottom, keyboardAvoidancePadding(safeAreaBottom: proxy.safeAreaInsets.bottom))
                    .animation(.easeOut(duration: 0.25), value: effectManager.keyboardHeight)
                    .animation(.easeOut(duration: 0.25), value: isInputFocused)
                    .onChange(of: effectManager.keyboardHeight) { oldHeight, newHeight in
                        if newHeight > oldHeight && newHeight > 0 {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(100))
                                scrollToBottomTrigger.toggle()
                            }
                        }
                    }
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in availableWidth = newWidth }
                }
            }
            .background(
                ((edgeSidebarTitleContext == nil ? nil : sidebarThemeColors?.background)
                    ?? Color(uiColor: .systemGroupedBackground)).ignoresSafeArea(.container)
            )
            .navigationTitle("AI Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(edgeSidebarTitleContext == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if edgeSidebarTitleContext == nil {
                    if showCloseButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") {
                                dismiss()
                            }
                            .keyboardShortcut(.escape, modifiers: [])
                        }
                    }

                    if session.isConnected {
                        ToolbarItem(placement: .principal) {
                            modelPickerAndEffortControls
                        }
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if shouldShowNewChatButton {
                            newChatButton
                        }

                        overflowMenu
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                AIAgentSettingsSheet()
            }
            .onChange(of: showSettings) { _, isShowing in
                // Refresh model cache when settings sheet closes
                if !isShowing {
                    refreshModelCache()
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { showError = false }
            } message: {
                Text(errorMessage)
            }
            .task(id: session.id) {
                await connectIfNeeded()
            }
            .onAppear {
                // Refresh model cache on appear
                refreshModelCache()
                scheduleAutoFocusIfNeeded(isConnected: session.isConnected)
            }
            .onChange(of: session.isConnected) { _, isConnected in
                scheduleAutoFocusIfNeeded(isConnected: isConnected)
            }
        }
        .interactiveDismissDisabled(session.state.isBusy)
        .focusable()
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(keys: aiToggleKeys, phases: .down) { keyPress in
            // Toggle shortcut (default Cmd-I) closes the sidebar when inside.
            if keyPress.modifiers == aiToggleModifiers {
                dismiss()
                return .handled
            }
            return .ignored
        }
    }

    private var shouldShowNewChatButton: Bool {
        session.isConnected && !session.messages.isEmpty
    }

    private var newChatButton: some View {
        Button(action: {
            Task { await session.resetToNewChat() }
        }) {
            Image(systemName: "square.and.pencil")
        }
        .disabled(session.state.isBusy)
    }

    private var overflowMenu: some View {
        AIAgentOverflowMenu(
            sessionID: session.id,
            approvalMode: $approvalMode,
            isConnected: session.isConnected,
            presentationMode: AICredentialsManager.shared.aiAgentPresentationMode,
            onSettings: { showSettings = true },
            onRefreshFingerprint: {
                Task { await session.collectFingerprint(forceRefresh: true) }
            },
            onDisconnect: { Task { await session.disconnect() } },
            onSwitchPresentationMode: switchPresentationMode
        )
        .equatable()
    }

    private var modelPickerAndEffortControls: some View {
        HStack(spacing: 6) {
            AIAgentModelPickerToolbar(
                sessionID: session.id,
                selectedModelID: $selectedModelID,
                cachedModels: cachedModels,
                availableWidth: max(120, availableWidth - (showsStandaloneEffortCapsule ? 70 : 0)),
                useWindowThemeColors: useWindowThemeColors,
                themeBackgroundHex: themeColors?.background,
                effortContext: chatGPTEffortContext,
                selectedEffort: selectedEffort,
                showsEmbeddedEffort: chatGPTEffortContext != nil && !showsStandaloneEffortCapsule,
                onSelectionChange: handleModelSelectionChange,
                onEffortChange: handleEffortChange
            )
            .equatable()

            if showsStandaloneEffortCapsule, let effortContext = chatGPTEffortContext {
                AIAgentReasoningEffortToolbar(
                    sessionID: session.id,
                    modelID: effortContext.modelID,
                    ladder: effortContext.ladder,
                    defaultEffort: effortContext.defaultEffort,
                    selectedEffort: selectedEffort,
                    useWindowThemeColors: useWindowThemeColors,
                    themeBackgroundHex: themeColors?.background,
                    onChange: handleEffortChange
                )
                .equatable()
            }
        }
    }

    // MARK: - Connection Status

    private var connectionStatusBar: some View {
        HStack(spacing: 8) {
            if session.isConnecting {
                ProgressView()
                    .scaleEffect(0.8)

                Text("Connecting to \(session.displayName)...")
                    .font(.callout)
                    .foregroundColor(.secondary)

                Spacer()
            } else {
                Image(systemName: "wifi.slash")
                    .foregroundColor(.secondary)

                Text("Disconnected from \(session.displayName)")
                    .font(.callout)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Reconnect") {
                    Task { await connectIfNeeded(force: true) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private var connectingView: some View {
        if session.isConnecting {
            VStack(spacing: 20) {
                Spacer()

                ProgressView()
                    .scaleEffect(1.5)

                VStack(spacing: 8) {
                    Text("Connecting")
                        .font(.headline)

                    Text(session.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        } else {
            disconnectedView
        }
    }

    @ViewBuilder
    private var disconnectedView: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundColor(.secondary)

                Text("Disconnected")
                    .font(.headline)

                Text(session.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: { Task { await connectIfNeeded(force: true) } }) {
                Text("Reconnect")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            // Thin context-usage indicator sits above the text field so it gets room to render
            // the full "used / budget" figure without competing with the toolbar model picker.
            if shouldShowContextBadge {
                HStack {
                    Spacer()
                    contextUsageBadge
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 2)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                // Text input with approval mode color indicator
                // Enable autocorrect when using virtual keyboard, disable for hardware keyboard
                TextField("Ask Rootshell...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...5)
                    .autocorrectionDisabled(KeyboardTracker.shared.isHardwareKeyboard)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(approvalModeBorderColor, lineWidth: 2)
                    )
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }
                    .onChange(of: inputText) { _, newValue in
                        // Workaround for Mac Catalyst: onSubmit doesn't fire on Return key
                        // Detect newline character and trigger send
                        if newValue.hasSuffix("\n") {
                            inputText.removeLast()
                            sendMessage()
                        }
                    }

                // Send button
                Button(action: sendMessage) {
                    Image(systemName: session.state.isBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(canSend ? .accentColor : .secondary)
                }
                .disabled(!canSend && !session.state.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemBackground))
        }
    }

    // MARK: - Model Picker

    private func refreshModelCache() {
        let cm = AICredentialsManager.shared
        // The OpenAI slot is auth-mode-exclusive: API-key lineup or the
        // ChatGPT subscription lineup, never both.
        let chatGPTMode = cm.openAIAuthMode == .chatgptSignIn
        cachedModels.hasOpenAI = !chatGPTMode && cm.hasAPIKey(for: OpenAIProvider.providerID)
        cachedModels.hasChatGPT = chatGPTMode && cm.hasChatGPTSignIn
        cachedModels.chatgptModels = cachedModels.hasChatGPT ? ChatGPTModelStore.shared.providerModels : []
        cachedModels.chatgptReasoning = cachedModels.hasChatGPT ? ChatGPTModelStore.shared.models : []
        cachedModels.hasAnthropic = cm.hasAnthropicAPIKey
        cachedModels.hasBedrock = cm.hasBedrockConfigured
        cachedModels.hasGoogle = cm.hasGoogleAPIKey
        cachedModels.hasOpenRouter = cm.hasOpenRouterAPIKey && !cm.openRouterFavoriteModels.isEmpty
        cachedModels.openRouterModels = cm.openRouterFavoriteModels
        // No API-key requirement: local endpoints are routinely unauthenticated, and gating on a
        // key made them vanish from the picker instead of failing visibly.
        cachedModels.customProviders = cm.customProviders
            .filter { $0.isEnabled && !$0.allModels.isEmpty }
            .map { CachedCustomProvider(name: $0.name, models: $0.allModels) }

        // Build display name lookup
        var names: [String: String] = [:]
        AIProviderModel.openAIModels.forEach { names[$0.id] = $0.displayName }
        cachedModels.chatgptModels.forEach { names[$0.id] = $0.displayName }
        AIProviderModel.anthropicModels.forEach { names[$0.id] = $0.displayName }
        AIProviderModel.bedrockModels.forEach { names[$0.id] = $0.displayName }
        AIProviderModel.googleModels.forEach { names[$0.id] = $0.displayName }
        cachedModels.openRouterModels.forEach { names[$0.id] = $0.displayName }
        cachedModels.customProviders.forEach { provider in
            provider.models.forEach { names[$0.id] = $0.displayName }
        }
        cachedModels.displayNames = names

        selectedEffort = ChatGPTReasoningSettings.storedEffort(for: selectedModelID)

        // A stale lineup refreshes in the background; fold the result back in.
        if cachedModels.hasChatGPT {
            Task {
                await ChatGPTModelStore.shared.refreshIfStale()
                cachedModels.chatgptModels = ChatGPTModelStore.shared.providerModels
                cachedModels.chatgptReasoning = ChatGPTModelStore.shared.models
                var updated = cachedModels.displayNames
                cachedModels.chatgptModels.forEach { updated[$0.id] = $0.displayName }
                cachedModels.displayNames = updated
            }
        }
    }

    /// The effort-switcher inputs for the selected model; nil hides the control
    /// (non-ChatGPT model selected, or the model reports no ladder).
    private var chatGPTEffortContext: ChatGPTEffortContext? {
        guard cachedModels.hasChatGPT,
              let info = cachedModels.chatgptReasoning.first(where: { $0.id == selectedModelID }),
              !info.supportedEfforts.isEmpty else {
            return nil
        }
        return ChatGPTEffortContext(
            modelID: info.id,
            ladder: info.supportedEfforts,
            defaultEffort: info.defaultEffort ?? .medium
        )
    }

    /// The standalone effort capsule needs its own toolbar real estate; below
    /// this width (iPhone, iPad Slide Over) it collides with the Close button
    /// and trailing icons, so the switcher folds into the model picker menu.
    private var showsStandaloneEffortCapsule: Bool {
        chatGPTEffortContext != nil && availableWidth >= 520
    }

    private func handleEffortChange(_ effort: ChatGPTReasoningEffort?) {
        selectedEffort = effort
        // Resolved at request-build time by ChatGPTProvider; no session rebuild.
        ChatGPTReasoningSettings.setEffort(effort, for: selectedModelID)
    }

    /// Full metadata for the currently selected model, if resolvable.
    private var currentModel: AIProviderModel? {
        // ChatGPT first: discovered ids can shadow the hardcoded OpenAI list
        // (e.g. gpt-5.6-sol exists in both) with different context windows.
        if let m = cachedModels.chatgptModels.first(where: { $0.id == selectedModelID }) { return m }
        if let m = AIProviderModel.openAIModel(id: selectedModelID) { return m }
        if let m = AIProviderModel.anthropicModel(id: selectedModelID) { return m }
        if let m = AIProviderModel.bedrockModel(id: selectedModelID) { return m }
        if let m = AIProviderModel.googleModel(id: selectedModelID) { return m }
        if let m = cachedModels.openRouterModels.first(where: { $0.id == selectedModelID }) { return m }
        for provider in cachedModels.customProviders {
            if let m = provider.models.first(where: { $0.id == selectedModelID }) { return m }
        }
        return nil
    }

    /// Usable input budget = total context window minus the completion reservation. nil when the
    /// provider doesn't publish a window or no response has arrived yet.
    private var currentInputBudget: Int? {
        guard let model = currentModel,
              let windowTokens = model.contextWindowTokens,
              windowTokens > 0,
              session.lastPromptTokens > 0 else {
            return nil
        }
        return max(1, windowTokens - model.effectiveMaxCompletionTokens)
    }

    /// Whether the input-area badge should render. Gating at the container level avoids stray
    /// padding when the badge is hidden.
    private var shouldShowContextBadge: Bool {
        currentInputBudget != nil
    }

    /// Compact "input tokens / usable input budget" indicator.
    /// The denominator is contextWindow − reservedCompletionTokens, because the input prompt can't
    /// occupy the completion budget — dividing by the raw window would mask real pressure.
    /// Hidden when the provider doesn't expose a window, or no response has arrived yet.
    @ViewBuilder
    private var contextUsageBadge: some View {
        if let inputBudget = currentInputBudget {
            let used = session.lastPromptTokens
            let fraction = min(1.0, Double(used) / Double(inputBudget))
            HStack(spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(contextBadgeColor(fraction).opacity(0.22))
                        Capsule()
                            .fill(contextBadgeColor(fraction))
                            .frame(width: max(2, proxy.size.width * fraction))
                    }
                }
                .frame(width: 28, height: 4)
                Text("\(formatTokenCount(used)) / \(formatTokenCount(inputBudget))")
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundColor(contextBadgeColor(fraction))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(toolbarControlBackground)
            .clipShape(Capsule())
            .accessibilityLabel("Input tokens \(formatTokenCount(used)) of \(formatTokenCount(inputBudget)) budget, \(Int(fraction * 100)) percent")
        }
    }

    private func contextBadgeColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .secondary
    }

    /// Format a token count as "1.2k", "12k", "200k", "1.05M".
    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 10_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        if tokens < 1_000_000 { return "\(tokens / 1_000)k" }
        let millions = Double(tokens) / 1_000_000
        if millions < 10 { return String(format: "%.2fM", millions) }
        return String(format: "%.1fM", millions)
    }

    private func handleModelSelectionChange(_ newValue: String) {
        // Update global selection and session
        AICredentialsManager.shared.globalSelectedModelID = newValue
        session.updateModel(modelID: newValue)
        // Each ChatGPT model remembers its own reasoning override.
        selectedEffort = ChatGPTReasoningSettings.storedEffort(for: newValue)
    }

    // MARK: - Computed Properties

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !session.state.isBusy &&
        !session.state.isAwaitingUserAction
    }

    private var sshConfig: SSHConfig? {
        session.sshConfig
    }

    private var approvalModeBorderColor: Color {
        switch approvalMode {
        case .askAll: return .clear
        case .approveWritesOnly: return .blue.opacity(0.6)
        case .yolo: return .orange
        }
    }

    // MARK: - Theme-Adaptive Colors

    /// This tab's theme after overrides.
    private var themeColors: ThemeManager.ThemeInfo.ThemeColors? {
        themeManager.resolvedColors(tabId: tabID, windowId: nil)
    }

    /// Background color for toolbar controls (adapts to terminal theme)
    private var toolbarControlBackground: Color {
        guard useWindowThemeColors,
              let themeColors,
              let baseColor = Color(hex: themeColors.background) else {
            return Color(uiColor: .tertiarySystemFill)
        }

        if baseColor.isLight {
            return baseColor.blendedWithBlack(0.08)
        } else {
            return baseColor.blendedWithWhite(0.12)
        }
    }

    // MARK: - Actions

    private func keyboardAvoidancePadding(safeAreaBottom: CGFloat) -> CGFloat {
        guard isInputFocused else { return 0 }
        let keyboardHeight = effectManager.keyboardHeight
        guard keyboardHeight > 0 else { return 0 }
        return max(0, keyboardHeight - safeAreaBottom)
    }

    private func scheduleAutoFocusIfNeeded(isConnected: Bool) {
        guard isConnected else { return }

        Task { @MainActor in
            // Let the sheet/layout settle before focusing, otherwise the keyboard can cover the input on iPhone.
            try? await Task.sleep(for: .milliseconds(150))
            isInputFocused = true
        }
    }

    private func dismiss() {
        Task {
            session.cancel()
            isPresented = false
        }
    }

    private func sendMessage() {
        if session.state.isBusy {
            session.cancel()
            return
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        isInputFocused = false

        Task {
            await session.sendMessage(text)
        }
    }

    private func connectIfNeeded(force: Bool = false) async {
        if session.isConnecting {
            return
        }

        if session.isConnected && !force {
            return
        }

        if force, session.isConnected {
            await session.disconnect()
        }

        do {
            try await session.connect()
        } catch is CancellationError {
            // Disconnected while connecting (tab closed); nothing to report.
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func switchPresentationMode() {
        let currentMode = AICredentialsManager.shared.aiAgentPresentationMode
        let targetMode: AIAgentPresentationMode = currentMode == .sidebar ? .window : .sidebar

        // Post notification for MainView to handle the switch
        NotificationCenter.default.post(
            name: .aiAgentSwitchMode,
            object: AIAgentSwitchModeRequest(tabID: tabID, targetMode: targetMode)
        )
    }

}

// MARK: - Settings Sheet

struct AIAgentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AIAgentSettingsView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

// MARK: - Toolbar Subviews
//
// Extracted into their own View structs so SwiftUI can short-circuit body
// re-evaluation when the parent (`AIAgentOverlayView`) re-renders on each
// ~100ms streaming tick. Without this isolation the underlying `UIMenu` is
// rebuilt on every tick and visibly flickers.
//
// Each struct conforms to `Equatable` and is invoked via `.equatable()` at the
// call site so SwiftUI uses the hand-written `==` (which intentionally ignores
// the action closures — closures capture parent state and would otherwise
// always compare unequal). All other inputs (binding, cached value data,
// width, theme snapshot) are stable across streaming ticks, so `==` returns
// `true` and the menu body is skipped.

private struct AIAgentModelPickerToolbar: View, Equatable {
    /// Identifies the underlying session. Included in `==` so that swapping to
    /// a different session in the AI Agent window forces a rebuild even when
    /// the visible inputs (selectedModelID, cached models, theme) happen to
    /// match — otherwise SwiftUI would keep the prior view and its
    /// `onSelectionChange` closure would still target the old session via
    /// `session.updateModel(modelID:)` capture.
    let sessionID: UUID
    @Binding var selectedModelID: String
    let cachedModels: CachedModelData
    let availableWidth: CGFloat
    let useWindowThemeColors: Bool
    let themeBackgroundHex: String?
    /// Reasoning inputs for the selected ChatGPT model, nil otherwise.
    let effortContext: ChatGPTEffortContext?
    /// The stored per-model override; nil = model default.
    let selectedEffort: ChatGPTReasoningEffort?
    /// True on narrow layouts where the standalone effort capsule doesn't fit
    /// and the switcher renders as a submenu of this menu instead.
    let showsEmbeddedEffort: Bool
    let onSelectionChange: (String) -> Void
    let onEffortChange: (ChatGPTReasoningEffort?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID &&
        lhs.selectedModelID == rhs.selectedModelID &&
        lhs.cachedModels == rhs.cachedModels &&
        lhs.availableWidth == rhs.availableWidth &&
        lhs.useWindowThemeColors == rhs.useWindowThemeColors &&
        lhs.themeBackgroundHex == rhs.themeBackgroundHex &&
        lhs.effortContext == rhs.effortContext &&
        lhs.selectedEffort == rhs.selectedEffort &&
        lhs.showsEmbeddedEffort == rhs.showsEmbeddedEffort
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        Menu {
            let sections = modelSections

            if sections.isEmpty {
                Text("No providers configured")
            } else {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section(header: Text(section.title)) {
                        ForEach(section.models) { model in
                            Button {
                                selectModelFromMenu(model.id)
                            } label: {
                                HStack {
                                    Text(model.displayName)
                                    if model.id == selectedModelID {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }

            embeddedEffortMenu
            chatGPTPlanSection
        } label: {
            label
        }
        #else
        Menu {
            Picker("Model", selection: $selectedModelID) {
                modelOptions
            }

            embeddedEffortMenu
            chatGPTPlanSection
        } label: {
            label
        }
        .onChange(of: selectedModelID) { _, newValue in
            onSelectionChange(newValue)
        }
        #endif
    }

    /// The narrow-layout effort switcher, rendered as a submenu at the bottom
    /// of the model menu.
    @ViewBuilder
    private var embeddedEffortMenu: some View {
        if showsEmbeddedEffort, let context = effortContext {
            let effective = ChatGPTReasoningEffort.clampDown(
                selectedEffort ?? context.defaultEffort,
                to: context.ladder
            )
            Section {
                Menu {
                    Button {
                        onEffortChange(nil)
                    } label: {
                        HStack {
                            Text("Default (\(context.defaultEffort.displayName))")
                            if selectedEffort == nil {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(context.ladder, id: \.self) { effort in
                        Button {
                            onEffortChange(effort)
                        } label: {
                            HStack {
                                Text(effort.displayName)
                                if selectedEffort == effort {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Reasoning: \(effective.displayName)", systemImage: "brain")
                }
            }
        }
    }

    /// Shown while the selected model runs on the user's ChatGPT plan.
    @ViewBuilder
    private var chatGPTPlanSection: some View {
        if cachedModels.chatgptModels.contains(where: { $0.id == selectedModelID }) {
            Section("Using ChatGPT plan") {
                Link(destination: ChatGPTOAuth.manageUsageURL) {
                    Label("Manage usage", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            if !hasAnyModels {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
            }
            Text(currentModelDisplayName)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                // Calculate max width: screen width minus toolbar buttons and margins
                // Close button (~60) + New Chat (~44) + Menu (~44) + nav margins (~32) + picker chrome (~40)
                .frame(maxWidth: max(50, availableWidth - 240))
            Image(systemName: "chevron.down")
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .foregroundColor(hasAnyModels ? toolbarTextColor : .orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(toolbarControlBackground)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var modelOptions: some View {
        if cachedModels.hasOpenAI {
            Section(header: Text("OpenAI")) {
                ForEach(AIProviderModel.openAIModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }

        if cachedModels.hasChatGPT {
            Section(header: Text("ChatGPT")) {
                ForEach(cachedModels.chatgptModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }

        if cachedModels.hasAnthropic {
            Section(header: Text("Anthropic")) {
                ForEach(AIProviderModel.anthropicModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }

        if cachedModels.hasBedrock {
            Section(header: Text("AWS Bedrock")) {
                ForEach(AIProviderModel.bedrockModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }

        if cachedModels.hasGoogle {
            Section(header: Text("Google")) {
                ForEach(AIProviderModel.googleModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }

        if cachedModels.hasOpenRouter {
            Section(header: Text("OpenRouter")) {
                ForEach(cachedModels.openRouterModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }

        ForEach(cachedModels.customProviders, id: \.name) { provider in
            Section(header: Text(provider.name)) {
                ForEach(provider.models) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }
    }

    private var currentModelDisplayName: String {
        if selectedModelID.isEmpty {
            return "No Provider"
        }
        return cachedModels.displayNames[selectedModelID] ?? "Model"
    }

    private var hasAnyModels: Bool {
        cachedModels.hasOpenAI || cachedModels.hasChatGPT ||
        cachedModels.hasAnthropic ||
        cachedModels.hasBedrock ||
        cachedModels.hasGoogle || cachedModels.hasOpenRouter ||
        !cachedModels.customProviders.isEmpty
    }

    private var modelSections: [(title: String, models: [AIProviderModel])] {
        var sections: [(String, [AIProviderModel])] = []

        if cachedModels.hasOpenAI {
            sections.append(("OpenAI", AIProviderModel.openAIModels))
        }
        if cachedModels.hasChatGPT {
            sections.append(("ChatGPT", cachedModels.chatgptModels))
        }
        if cachedModels.hasAnthropic {
            sections.append(("Anthropic", AIProviderModel.anthropicModels))
        }
        if cachedModels.hasBedrock {
            sections.append(("AWS Bedrock", AIProviderModel.bedrockModels))
        }
        if cachedModels.hasGoogle {
            sections.append(("Google", AIProviderModel.googleModels))
        }
        if cachedModels.hasOpenRouter {
            sections.append(("OpenRouter", cachedModels.openRouterModels))
        }

        cachedModels.customProviders.forEach { provider in
            sections.append((provider.name, provider.models))
        }

        return sections
    }

    private func selectModelFromMenu(_ modelID: String) {
        guard selectedModelID != modelID else { return }
        selectedModelID = modelID
        onSelectionChange(modelID)
    }

    private var themeBaseColor: Color? {
        guard useWindowThemeColors, let hex = themeBackgroundHex else { return nil }
        return Color(hex: hex)
    }

    private var toolbarTextColor: Color {
        guard let baseColor = themeBaseColor else { return .primary }
        return baseColor.isLight ? Color(white: 0.1) : Color(white: 0.95)
    }

    private var toolbarControlBackground: Color {
        guard let baseColor = themeBaseColor else {
            return Color(uiColor: .tertiarySystemFill)
        }
        return baseColor.isLight
            ? baseColor.blendedWithBlack(0.08)
            : baseColor.blendedWithWhite(0.12)
    }
}

/// Reasoning-level quick switch for ChatGPT subscription models. Shown next to
/// the model picker only while a ChatGPT model with a known effort ladder is
/// selected. Same Equatable/closure-ignoring pattern as the model picker.
private struct AIAgentReasoningEffortToolbar: View, Equatable {
    let sessionID: UUID
    let modelID: String
    let ladder: [ChatGPTReasoningEffort]
    let defaultEffort: ChatGPTReasoningEffort
    /// The stored override; nil means the model's default applies.
    let selectedEffort: ChatGPTReasoningEffort?
    let useWindowThemeColors: Bool
    let themeBackgroundHex: String?
    let onChange: (ChatGPTReasoningEffort?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID &&
        lhs.modelID == rhs.modelID &&
        lhs.ladder == rhs.ladder &&
        lhs.defaultEffort == rhs.defaultEffort &&
        lhs.selectedEffort == rhs.selectedEffort &&
        lhs.useWindowThemeColors == rhs.useWindowThemeColors &&
        lhs.themeBackgroundHex == rhs.themeBackgroundHex
    }

    private var effectiveEffort: ChatGPTReasoningEffort {
        ChatGPTReasoningEffort.clampDown(selectedEffort ?? defaultEffort, to: ladder)
    }

    var body: some View {
        Menu {
            Button {
                onChange(nil)
            } label: {
                HStack {
                    Text("Default (\(defaultEffort.displayName))")
                    if selectedEffort == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(ladder, id: \.self) { effort in
                Button {
                    onChange(effort)
                } label: {
                    HStack {
                        Text(effort.displayName)
                        if selectedEffort == effort {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text(effectiveEffort.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .foregroundColor(toolbarTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(toolbarControlBackground)
            .clipShape(Capsule())
        }
        .accessibilityLabel("Reasoning level \(effectiveEffort.displayName)")
    }

    private var themeBaseColor: Color? {
        guard useWindowThemeColors, let hex = themeBackgroundHex else { return nil }
        return Color(hex: hex)
    }

    private var toolbarTextColor: Color {
        guard let baseColor = themeBaseColor else { return .primary }
        return baseColor.isLight ? Color(white: 0.1) : Color(white: 0.95)
    }

    private var toolbarControlBackground: Color {
        guard let baseColor = themeBaseColor else {
            return Color(uiColor: .tertiarySystemFill)
        }
        return baseColor.isLight
            ? baseColor.blendedWithBlack(0.08)
            : baseColor.blendedWithWhite(0.12)
    }
}

private struct AIAgentOverflowMenu: View, Equatable {
    /// Identifies the underlying session. Included in `==` so that swapping to
    /// a different session in the AI Agent window forces a rebuild even when
    /// approvalMode/presentationMode/isConnected match — otherwise SwiftUI
    /// would keep the prior view and its onDisconnect/onRefreshFingerprint
    /// closures would target the previously selected session.
    let sessionID: UUID
    @Binding var approvalMode: CommandApprovalMode
    let isConnected: Bool
    /// Snapshot of `AICredentialsManager.shared.aiAgentPresentationMode`. Lifted
    /// to a parameter so it participates in the Equatable comparison — without
    /// this the menu would render stale "Open in Window/Sidebar" text after the
    /// user changes the mode in Settings (the parent re-renders on Settings
    /// dismissal but `==` would otherwise return true and skip the rebuild).
    let presentationMode: AIAgentPresentationMode
    let onSettings: () -> Void
    let onRefreshFingerprint: () -> Void
    let onDisconnect: () -> Void
    let onSwitchPresentationMode: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID &&
        lhs.approvalMode == rhs.approvalMode &&
        lhs.isConnected == rhs.isConnected &&
        lhs.presentationMode == rhs.presentationMode
    }

    var body: some View {
        Menu {
            Picker("Approval Mode", selection: $approvalMode) {
                ForEach(CommandApprovalMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .onChange(of: approvalMode) { _, newValue in
                AICredentialsManager.shared.approvalMode = newValue
            }

            Divider()

            #if os(iOS) || targetEnvironment(macCatalyst)
            if UIDevice.current.userInterfaceIdiom != .phone {
                Button(action: onSwitchPresentationMode) {
                    Label(
                        presentationMode == .sidebar ? "Open in Window" : "Open in Sidebar",
                        systemImage: presentationMode == .sidebar ? "macwindow" : "sidebar.right"
                    )
                }

                Divider()
            }
            #endif

            Button(action: onSettings) {
                Label("Settings", systemImage: "gear")
            }

            if isConnected {
                Button(action: onRefreshFingerprint) {
                    Label("Refresh Host Info", systemImage: "arrow.clockwise")
                }

                Divider()

                Button(role: .destructive, action: onDisconnect) {
                    Label("Disconnect", systemImage: "wifi.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
#endif
