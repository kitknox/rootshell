#if !CHINA_BUILD
//
//  AICredentialsManager.swift
//  rootshell
//
//  Secure storage for AI provider API keys using Keychain
//

import Foundation
import Observation
import os.log

/// API format options for custom endpoints
enum AIAPIFormat: String, Codable, CaseIterable, Sendable {
    case openAIResponses = "openai_responses"
    case openAIChatCompletions = "openai_chat"
    case anthropicMessages = "anthropic"

    var displayName: String {
        switch self {
        case .openAIResponses: return "OpenAI Responses API"
        case .openAIChatCompletions: return "OpenAI Chat Completions"
        case .anthropicMessages: return "Anthropic Messages API"
        }
    }

    var description: String {
        switch self {
        case .openAIResponses: return "Default OpenAI format with structured responses"
        case .openAIChatCompletions: return "Legacy chat completions format"
        case .anthropicMessages: return "Anthropic Messages API with streaming"
        }
    }
}

/// Command approval modes for AI Agent
enum CommandApprovalMode: String, Codable, CaseIterable, Sendable {
    case askAll = "ask_all"
    case approveWritesOnly = "approve_writes_only"
    case yolo = "yolo"

    var displayName: String {
        switch self {
        case .askAll: return "Ask All"
        case .approveWritesOnly: return "Approve Writes"
        case .yolo: return "YOLO"
        }
    }

    var description: String {
        switch self {
        case .askAll: return "Require approval for every command"
        case .approveWritesOnly: return "Auto-approve read commands, ask for writes"
        case .yolo: return "Auto-approve all commands"
        }
    }

    var icon: String {
        switch self {
        case .askAll: return "hand.raised"
        case .approveWritesOnly: return "pencil.slash"
        case .yolo: return "bolt.fill"
        }
    }
}

extension Notification.Name {
    /// Posted whenever AI credentials change (API keys added/updated/removed,
    /// or custom-provider list mutated). Active `AIAgentSession` instances
    /// observe this to rebuild their provider without requiring an app restart.
    static let aiCredentialsChanged = Notification.Name("AICredentialsChanged")
}

/// How the OpenAI slot authenticates: metered API key against api.openai.com,
/// or a ChatGPT subscription via Codex OAuth. The modes are exclusive; flipping
/// swaps both the model lineup and the provider implementation.
enum OpenAIAuthMode: String, Codable, CaseIterable, Sendable {
    case apiKey
    case chatgptSignIn

    var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .chatgptSignIn: return "ChatGPT"
        }
    }
}

/// Manages secure storage of AI provider API keys
@Observable
@MainActor
final class AICredentialsManager {
    // MARK: - Singleton

    static let shared = AICredentialsManager()

    // MARK: - Private Properties

    @ObservationIgnored
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AICredentialsManager")
    @ObservationIgnored
    private let keychain = KeychainManager.shared
    @ObservationIgnored
    private let service = "com.ghostty.ai.apikey"

    // User defaults keys
    @ObservationIgnored
    private let selectedModelKey = "ai.selectedModel"
    @ObservationIgnored
    private let legacyYoloModeKey = "ai.yoloMode.enabled"  // For migration only
    @ObservationIgnored
    private let aiAgentFullScreenKey = "ai.agent.fullscreen.mode"  // Legacy, for migration
    @ObservationIgnored
    private let temperatureKeyPrefix = "ai.temperature"
    @ObservationIgnored
    private let openAIAuthModeKey = "ai.openai.authMode"

    /// Model IDs we no longer offer, mapped to their replacement. Stored selections
    /// are rewritten on launch — an unmapped ID resolves to no provider at all.
    private nonisolated static let legacyModelMigrations: [String: String] = [
        "gpt-5.4": "gpt-5.6-sol",
        "gpt-5.4-mini-2026-03-17": "gpt-5.6-terra",
        "gpt-5.4-nano-2026-03-17": "gpt-5.6-luna",
        "claude-opus-4-8": "claude-opus-5",
        "bedrock-claude-opus-4-8": "bedrock-claude-opus-5",
    ]

    // Keychain accounts
    @ObservationIgnored
    private let anthropicAccount = "anthropic"
    @ObservationIgnored
    private let googleAccount = "google"
    @ObservationIgnored
    private let openRouterAccount = "openrouter"

    // Bedrock UserDefaults keys (no Keychain entry — credentials live in the
    // linked CloudAccount's existing Keychain record).
    @ObservationIgnored
    private let bedrockCloudAccountIDKey = "ai.bedrock.cloudAccountID"

    // OpenRouter UserDefaults keys
    @ObservationIgnored
    private let openRouterModelsKey = "ai.openrouter.discoveredModels"

    /// Registered scalar keys this manager mirrors into its backing storage.
    @ObservationIgnored
    private static let storeKeyNames: Set<String> = [
        Settings.AI.globalSelectedModel.name, Settings.AI.approvalMode.name, Settings.AI.customProviders.name,
        Settings.AI.openRouterFavorites.name, Settings.AI.webSearchEnabled.name, Settings.AI.webSearchEngine.name,
        Settings.AI.commitMessageEnabled.name, Settings.AI.commitMessageModel.name,
        Settings.AI.presentationMode.name, Settings.AI.sidebarWidth.name, Settings.AI.bedrockRegion.name,
    ]

    /// In-flight model-list refreshes, keyed by provider, so a second request for the same
    /// provider replaces the first instead of racing it.
    @ObservationIgnored
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Observable Storage (backed by UserDefaults)

    /// The globally selected model ID (used by toolbar picker and session)
    private var _globalSelectedModelID: String = AIProviderModel.defaultModelID

    /// All configured custom providers
    private var _customProviders: [CustomProviderConfig] = []

    /// Command approval mode for AI Agent
    private var _approvalMode: CommandApprovalMode = .askAll

    /// Whether web search is enabled for AI Agent
    private var _webSearchEnabled: Bool = true

    /// Default search engine for AI Agent
    private var _defaultSearchEngine: String = "duckduckgo"

    /// AI Agent presentation mode (sidebar or window) - iPad/Catalyst only
    private var _aiAgentPresentationMode: AIAgentPresentationMode = .sidebar

    /// Sidebar width for AI Agent in sidebar mode
    private var _aiAgentSidebarWidth: CGFloat = 400

    /// Whether AI-generated commit messages are enabled for git commit
    private var _aiCommitMessageEnabled: Bool = false

    /// Model ID selected for AI commit messages (empty = not selected)
    private var _aiCommitMessageModelID: String = ""

    // MARK: - Observable API Key State (for SwiftUI refresh)

    /// Tracks whether Google API key is configured (triggers view updates)
    private var _hasGoogleAPIKey: Bool = false

    /// Tracks whether Anthropic API key is configured (triggers view updates)
    private var _hasAnthropicAPIKey: Bool = false

    /// Tracks whether OpenRouter API key is configured (triggers view updates)
    private var _hasOpenRouterAPIKey: Bool = false

    /// Which auth path the OpenAI slot uses.
    private var _openAIAuthMode: OpenAIAuthMode = .apiKey

    /// Cached mirror of `ChatGPTCredentialStore.isSignedInCached` so SwiftUI
    /// observation fires on sign-in/out.
    private var _isChatGPTSignedIn: Bool = false

    /// OpenRouter favorite model IDs (only these appear in main model picker)
    private var _openRouterFavoriteModelIDs: Set<String> = []

    /// Full catalog of discovered OpenRouter models
    private var _openRouterDiscoveredModels: [AIProviderModel] = []

    /// Linked AWS Cloud account ID for the Bedrock provider. Nil = not configured.
    /// The actual AWS credentials live in the CloudAccount's Keychain record;
    /// this is just a pointer.
    private var _bedrockCloudAccountID: UUID?

    /// Region used for Bedrock API calls. Stored separately from the linked
    /// AWS account's region so the user can run Bedrock in (say) us-east-1
    /// even if their AWS account's primary region is eu-north-1, where
    /// Bedrock isn't available.
    private var _bedrockRegion: String = BedrockRegions.defaultRegion

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared
        _globalSelectedModelID = store.get(Settings.AI.globalSelectedModel)

        // Load approval mode (with migration from legacy YOLO toggle)
        if UserDefaults.standard.object(forKey: Settings.AI.approvalMode.name) != nil {
            _approvalMode = store.get(Settings.AI.approvalMode)
        } else if UserDefaults.standard.bool(forKey: legacyYoloModeKey) {
            // Migration from old YOLO toggle
            _approvalMode = .yolo
            // Save in new format and clear old key
            store.set(Settings.AI.approvalMode, .yolo)
            UserDefaults.standard.removeObject(forKey: legacyYoloModeKey)
            Self.logger.info("Migrated YOLO mode setting to new approval mode format")
        } else {
            _approvalMode = .askAll
        }

        // Load custom providers
        if let data = store.get(Settings.AI.customProviders),
           let providers = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) {
            _customProviders = providers
        }

        // Load OpenRouter favorites
        _openRouterFavoriteModelIDs = Set(store.get(Settings.AI.openRouterFavorites))

        // Load OpenRouter discovered models
        if let data = UserDefaults.standard.data(forKey: openRouterModelsKey),
           let models = try? JSONDecoder().decode([AIProviderModel].self, from: data) {
            _openRouterDiscoveredModels = models
        }

        // Load web search settings
        _webSearchEnabled = store.get(Settings.AI.webSearchEnabled)
        _defaultSearchEngine = store.get(Settings.AI.webSearchEngine).rawValue

        // Load AI commit message settings
        _aiCommitMessageEnabled = store.get(Settings.AI.commitMessageEnabled)
        _aiCommitMessageModelID = store.get(Settings.AI.commitMessageModel)
        migrateLegacyModelSelections()

        // Load AI Agent presentation mode (with migration from legacy fullscreen bool)
        if UserDefaults.standard.object(forKey: Settings.AI.presentationMode.name) != nil {
            _aiAgentPresentationMode = store.get(Settings.AI.presentationMode)
        } else if UserDefaults.standard.bool(forKey: aiAgentFullScreenKey) {
            // Migration from old fullscreen boolean
            _aiAgentPresentationMode = .window
            store.set(Settings.AI.presentationMode, .window)
            UserDefaults.standard.removeObject(forKey: aiAgentFullScreenKey)
            Self.logger.info("Migrated AI Agent fullscreen mode to presentation mode: window")
        } else {
            _aiAgentPresentationMode = .sidebar
        }

        // Load sidebar width
        let savedWidth = CGFloat(store.get(Settings.AI.sidebarWidth))
        _aiAgentSidebarWidth = savedWidth >= 280 ? savedWidth : 400  // Default 400, minimum 280

        // Initialize API key state from Keychain
        _hasAnthropicAPIKey = loadAPIKey(for: anthropicAccount) != nil
        _hasGoogleAPIKey = loadAPIKey(for: googleAccount) != nil
        _hasOpenRouterAPIKey = loadAPIKey(for: openRouterAccount) != nil

        // Bedrock state — pointer to a linked Cloud account, plus region override.
        if let stored = UserDefaults.standard.string(forKey: bedrockCloudAccountIDKey),
           let uuid = UUID(uuidString: stored) {
            _bedrockCloudAccountID = uuid
        }
        let storedRegion = store.get(Settings.AI.bedrockRegion)
        if BedrockRegions.isSupported(storedRegion) {
            _bedrockRegion = storedRegion
        }

        // ChatGPT subscription state. The Keychain read happens on the store's
        // actor; the observable flag catches up a beat later.
        _openAIAuthMode = UserDefaults.standard.string(forKey: openAIAuthModeKey)
            .flatMap(OpenAIAuthMode.init(rawValue:)) ?? .apiKey
        Task { [weak self] in
            let signedIn = await ChatGPTCredentialStore.shared.refreshCachedState()
            self?._isChatGPTSignedIn = signedIn
        }

        SettingsRefreshHub.shared.register(keys: Self.storeKeyNames) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Mirrors externally applied store values into the backing storage.
    private func reload(keys: Set<String>) {
        let store = SettingsStore.shared
        if keys.contains(Settings.AI.globalSelectedModel.name) {
            _globalSelectedModelID = store.get(Settings.AI.globalSelectedModel)
        }
        if keys.contains(Settings.AI.approvalMode.name) {
            _approvalMode = store.get(Settings.AI.approvalMode)
        }
        if keys.contains(Settings.AI.customProviders.name) {
            if let data = store.get(Settings.AI.customProviders),
               let providers = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) {
                _customProviders = providers
            } else {
                _customProviders = []
            }
            NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
        }
        if keys.contains(Settings.AI.openRouterFavorites.name) {
            _openRouterFavoriteModelIDs = Set(store.get(Settings.AI.openRouterFavorites))
        }
        if keys.contains(Settings.AI.webSearchEnabled.name) {
            _webSearchEnabled = store.get(Settings.AI.webSearchEnabled)
        }
        if keys.contains(Settings.AI.webSearchEngine.name) {
            _defaultSearchEngine = store.get(Settings.AI.webSearchEngine).rawValue
        }
        if keys.contains(Settings.AI.commitMessageEnabled.name) {
            _aiCommitMessageEnabled = store.get(Settings.AI.commitMessageEnabled)
        }
        if keys.contains(Settings.AI.commitMessageModel.name) {
            _aiCommitMessageModelID = store.get(Settings.AI.commitMessageModel)
        }
        if keys.contains(Settings.AI.presentationMode.name) {
            _aiAgentPresentationMode = store.get(Settings.AI.presentationMode)
        }
        if keys.contains(Settings.AI.sidebarWidth.name) {
            let savedWidth = CGFloat(store.get(Settings.AI.sidebarWidth))
            _aiAgentSidebarWidth = savedWidth >= 280 ? savedWidth : 400
        }
        if keys.contains(Settings.AI.bedrockRegion.name) {
            let storedRegion = store.get(Settings.AI.bedrockRegion)
            _bedrockRegion = BedrockRegions.isSupported(storedRegion) ? storedRegion : BedrockRegions.defaultRegion
        }
    }

    /// Re-reads cached state from UserDefaults and Keychain.
    /// Call after restoring AI settings from a backup.
    func reloadFromDefaults() {
        let store = SettingsStore.shared
        _globalSelectedModelID = store.get(Settings.AI.globalSelectedModel)
        _approvalMode = store.get(Settings.AI.approvalMode)

        if let data = store.get(Settings.AI.customProviders),
           let providers = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) {
            _customProviders = providers
        }

        _openRouterFavoriteModelIDs = Set(store.get(Settings.AI.openRouterFavorites))

        if let data = UserDefaults.standard.data(forKey: openRouterModelsKey),
           let models = try? JSONDecoder().decode([AIProviderModel].self, from: data) {
            _openRouterDiscoveredModels = models
        }

        _webSearchEnabled = store.get(Settings.AI.webSearchEnabled)
        _defaultSearchEngine = store.get(Settings.AI.webSearchEngine).rawValue
        _aiCommitMessageEnabled = store.get(Settings.AI.commitMessageEnabled)
        _aiCommitMessageModelID = store.get(Settings.AI.commitMessageModel)
        migrateLegacyModelSelections()

        _aiAgentPresentationMode = store.get(Settings.AI.presentationMode)

        let savedWidth = CGFloat(store.get(Settings.AI.sidebarWidth))
        _aiAgentSidebarWidth = savedWidth >= 280 ? savedWidth : 400

        _hasAnthropicAPIKey = loadAPIKey(for: anthropicAccount) != nil
        _hasGoogleAPIKey = loadAPIKey(for: googleAccount) != nil
        _hasOpenRouterAPIKey = loadAPIKey(for: openRouterAccount) != nil

        // Reload Bedrock state too — backup restores can repopulate these.
        if let stored = UserDefaults.standard.string(forKey: bedrockCloudAccountIDKey),
           let uuid = UUID(uuidString: stored) {
            _bedrockCloudAccountID = uuid
        } else {
            _bedrockCloudAccountID = nil
        }
        let storedRegion = store.get(Settings.AI.bedrockRegion)
        _bedrockRegion = BedrockRegions.isSupported(storedRegion) ? storedRegion : BedrockRegions.defaultRegion

        // ChatGPT subscription state — backup restores can repopulate these.
        _openAIAuthMode = UserDefaults.standard.string(forKey: openAIAuthModeKey)
            .flatMap(OpenAIAuthMode.init(rawValue:)) ?? .apiKey
        ChatGPTModelStore.shared.reloadFromDefaults()
        Task { [weak self] in
            let signedIn = await ChatGPTCredentialStore.shared.refreshCachedState()
            self?._isChatGPTSignedIn = signedIn
        }
    }

    // MARK: - API Key Storage

    /// Saves an API key for a provider
    /// - Parameters:
    ///   - apiKey: The API key string
    ///   - providerID: The provider identifier (e.g., "openai")
    ///   - syncToiCloud: Whether to sync to iCloud Keychain
    /// - Throws: KeychainManager.KeychainError if save fails
    func saveAPIKey(_ apiKey: String, for providerID: String, syncToiCloud: Bool = true) throws {
        guard let keyData = apiKey.data(using: .utf8) else {
            Self.logger.error("Failed to encode API key to data")
            throw KeychainManager.KeychainError.dataConversionFailed
        }

        // First try to delete any existing key. Go straight to the keychain
        // helper so we do NOT post .aiCredentialsChanged mid-upsert — the
        // subsequent save posts once for both operations. Posting between the
        // delete and the save could briefly expose a state where the provider
        // has no key, causing `validatedSelectedModelID` to auto-correct the
        // global selection to a different provider that then wouldn't be
        // reverted when the save completes.
        try? deleteFromKeychain(account: providerID)

        // Save with appropriate storage level
        let storageLevel: KeyStorageLevel = syncToiCloud ? .iCloudSync : .backupOnly

        // Use the secure save method with storage level
        try saveToKeychain(
            keyData,
            account: providerID,
            storageLevel: storageLevel
        )

        Self.logger.info("Saved API key for provider: \(providerID), synced: \(syncToiCloud)")
        NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
    }

    /// Loads an API key for a provider
    /// - Parameter providerID: The provider identifier
    /// - Returns: The API key string, or nil if not found
    func loadAPIKey(for providerID: String) -> String? {
        do {
            let data = try loadFromKeychain(account: providerID)
            guard let apiKey = String(data: data, encoding: .utf8) else {
                Self.logger.error("Failed to decode API key data")
                return nil
            }
            return apiKey
        } catch KeychainManager.KeychainError.itemNotFound {
            // Expected case - no key configured yet
            return nil
        } catch {
            Self.logger.error("Failed to load API key: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes an API key for a provider
    /// - Parameter providerID: The provider identifier
    /// - Throws: KeychainManager.KeychainError if deletion fails
    func deleteAPIKey(for providerID: String) throws {
        try deleteFromKeychain(account: providerID)
        Self.logger.info("Deleted API key for provider: \(providerID)")
        NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
    }

    /// Checks if an API key exists for a provider
    /// - Parameter providerID: The provider identifier
    /// - Returns: true if an API key exists
    func hasAPIKey(for providerID: String) -> Bool {
        loadAPIKey(for: providerID) != nil
    }

    /// Lists all provider IDs that have stored API keys
    /// - Returns: Array of provider IDs
    func listProviderIDs() -> [String] {
        listKeychainAccounts()
    }

    // MARK: - Model Selection

    /// Rewrites retired built-in OpenAI model IDs while preserving the user's
    /// selected capability tier. Unrelated and custom model IDs are unchanged.
    private func migrateLegacyModelSelections() {
        let defaults = UserDefaults.standard

        if let migrated = Self.legacyModelMigrations[_globalSelectedModelID] {
            _globalSelectedModelID = migrated
            SettingsStore.shared.set(Settings.AI.globalSelectedModel, migrated)
        }

        let migratedProviders = [
            OpenAIProvider.providerID,
            AnthropicProvider.providerID,
            BedrockProvider.providerID,
        ]
        for providerID in migratedProviders {
            let key = "\(selectedModelKey).\(providerID)"
            if let saved = defaults.string(forKey: key),
               let migrated = Self.legacyModelMigrations[saved] {
                defaults.set(migrated, forKey: key)
            }
        }

        if let migrated = Self.legacyModelMigrations[_aiCommitMessageModelID] {
            _aiCommitMessageModelID = migrated
            SettingsStore.shared.set(Settings.AI.commitMessageModel, migrated)
        }
    }

    /// Gets the selected model ID for a provider
    /// - Parameter providerID: The provider identifier
    /// - Returns: The selected model ID, or the provider-appropriate default
    func selectedModelID(for providerID: String) -> String {
        let key = "\(selectedModelKey).\(providerID)"
        if let modelID = UserDefaults.standard.string(forKey: key) {
            return modelID
        }
        // Return provider-appropriate default
        switch providerID {
        case AnthropicProvider.providerID:
            return AIProviderModel.defaultAnthropicModelID
        case BedrockProvider.providerID:
            return AIProviderModel.defaultBedrockModelID
        case GeminiProvider.providerID:
            return AIProviderModel.defaultGoogleModelID
        default:
            return AIProviderModel.defaultModelID
        }
    }

    /// Sets the selected model ID for a provider
    /// - Parameters:
    ///   - modelID: The model ID to select
    ///   - providerID: The provider identifier
    func setSelectedModelID(_ modelID: String, for providerID: String) {
        let key = "\(selectedModelKey).\(providerID)"
        UserDefaults.standard.set(modelID, forKey: key)
        Self.logger.debug("Set selected model for \(providerID): \(modelID)")
    }

    // MARK: - Provider Configuration

    /// Configuration state for a provider
    struct ProviderConfiguration: Sendable {
        let providerID: String
        let hasAPIKey: Bool
        let selectedModelID: String
    }

    /// Gets the configuration state for a provider
    /// - Parameter providerID: The provider identifier
    /// - Returns: The provider configuration
    func configuration(for providerID: String) -> ProviderConfiguration {
        ProviderConfiguration(
            providerID: providerID,
            hasAPIKey: hasAPIKey(for: providerID),
            selectedModelID: selectedModelID(for: providerID)
        )
    }

    /// Creates an OpenAI provider if configured
    /// - Returns: An OpenAIProvider instance, or nil if not configured
    func createOpenAIProvider() -> OpenAIProvider? {
        guard let apiKey = loadAPIKey(for: OpenAIProvider.providerID) else {
            return nil
        }
        let modelID = selectedModelID(for: OpenAIProvider.providerID)
        return OpenAIProvider(apiKey: apiKey, selectedModelID: modelID)
    }

    /// Creates an Anthropic provider if configured
    /// - Returns: An AnthropicProvider instance, or nil if not configured
    func createAnthropicProvider() -> AnthropicProvider? {
        guard let apiKey = loadAnthropicAPIKey() else {
            return nil
        }
        let modelID = selectedModelID(for: AnthropicProvider.providerID)
        return AnthropicProvider(apiKey: apiKey, selectedModelID: modelID)
    }

    /// Creates a Google Gemini provider if configured
    /// - Returns: A GeminiProvider instance, or nil if not configured
    func createGoogleProvider() -> GeminiProvider? {
        guard let apiKey = loadGoogleAPIKey() else {
            return nil
        }
        let modelID = selectedModelID(for: GeminiProvider.providerID)
        return GeminiProvider(apiKey: apiKey, selectedModelID: modelID)
    }

    /// Creates a Bedrock provider for the given Bedrock-prefixed model ID.
    /// Returns nil if no Cloud account is linked. The deeper validation
    /// (account still exists, region supports Bedrock, model resolves) is
    /// performed by `BedrockProvider.isConfigured`.
    func createBedrockProvider(forModelID modelID: String) -> BedrockProvider? {
        guard let accountID = bedrockCloudAccountID else { return nil }
        return BedrockProvider(
            cloudAccountID: accountID,
            region: bedrockRegion,
            selectedModelID: modelID
        )
    }

    /// Creates a provider for a specific custom provider configuration
    /// - Parameters:
    ///   - config: The custom provider configuration
    ///   - modelID: The model ID to use
    /// - Returns: An AIProvider instance based on the provider's API format
    func createCustomProvider(config: CustomProviderConfig, modelID: String) -> (any AIProvider)? {
        // A local server (oMLX, Ollama, LM Studio) commonly needs no credential at all, so an
        // absent key is a valid configuration rather than a missing one.
        let apiKey = loadAPIKey(for: config.keychainAccount) ?? ""

        // The stored URL is passed through as typed; each provider resolves it to an API root in
        // its own init so every path lands on the same endpoint.
        switch config.apiFormat {
        case .openAIResponses, .openAIChatCompletions:
            return OpenAIProvider(apiKey: apiKey, baseURL: config.endpointURL, selectedModelID: modelID)
        case .anthropicMessages:
            return AnthropicProvider(apiKey: apiKey, baseURL: config.endpointURL, selectedModelID: modelID)
        }
    }

    // MARK: - Global Model Selection

    /// The globally selected model ID (used by toolbar picker and session)
    var globalSelectedModelID: String {
        get { _globalSelectedModelID }
        set {
            _globalSelectedModelID = newValue
            SettingsStore.shared.set(Settings.AI.globalSelectedModel, newValue)
            Self.logger.debug("Global selected model: \(newValue)")
        }
    }

    /// Gets a validated model ID - ensures the model exists in available providers
    /// Falls back to first available model if current selection is invalid
    var validatedSelectedModelID: String {
        let currentID = _globalSelectedModelID
        let available = allAvailableModels

        // If current selection exists in available models, use it
        if available.contains(where: { $0.id == currentID }) {
            return currentID
        }

        // Otherwise return first available model, or empty string if none
        if let firstModel = available.first {
            // Auto-correct the stored selection
            _globalSelectedModelID = firstModel.id
            SettingsStore.shared.set(Settings.AI.globalSelectedModel, firstModel.id)
            Self.logger.info("Auto-selected model \(firstModel.id) (previous selection unavailable)")
            return firstModel.id
        }

        return ""
    }

    // MARK: - Custom Providers (Multi-Provider Support)

    /// All configured custom providers
    var customProviders: [CustomProviderConfig] {
        get { _customProviders }
        set {
            _customProviders = newValue
            saveCustomProviders()
        }
    }

    /// Add a new custom provider
    func addCustomProvider(_ config: CustomProviderConfig) {
        var providers = customProviders
        providers.append(config)
        customProviders = providers
        Self.logger.info("Added custom provider: \(config.name)")
    }

    /// Update an existing custom provider
    func updateCustomProvider(_ config: CustomProviderConfig) {
        var providers = customProviders
        if let index = providers.firstIndex(where: { $0.id == config.id }) {
            providers[index] = config
            customProviders = providers
            Self.logger.debug("Updated custom provider: \(config.name)")
        }
    }

    /// Delete a custom provider (including its API key)
    func deleteCustomProvider(id: UUID) throws {
        var providers = customProviders
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }

        let provider = providers[index]
        try? deleteAPIKey(for: provider.keychainAccount)
        refreshTasks.removeValue(forKey: id)?.cancel()

        providers.remove(at: index)
        customProviders = providers
        Self.logger.info("Deleted custom provider: \(provider.name)")
    }

    /// Get a custom provider by ID
    func customProvider(id: UUID) -> CustomProviderConfig? {
        customProviders.first { $0.id == id }
    }

    /// Save API key for a custom provider
    func saveAPIKey(for provider: CustomProviderConfig, apiKey: String) throws {
        try saveAPIKey(apiKey, for: provider.keychainAccount, syncToiCloud: true)
    }

    /// Load API key for a custom provider
    func loadAPIKey(for provider: CustomProviderConfig) -> String? {
        loadAPIKey(for: provider.keychainAccount)
    }

    /// Check if a custom provider has an API key configured
    func hasAPIKey(for provider: CustomProviderConfig) -> Bool {
        loadAPIKey(for: provider) != nil
    }

    /// Refresh a provider's model list in the background.
    /// Owned by the manager rather than a view so the work survives the editor sheet being
    /// dismissed. A second call for the same provider replaces the in-flight one.
    func refreshDiscoveredModels(for providerID: UUID) {
        refreshTasks[providerID]?.cancel()
        // The entry is replaced, never cleared on completion: a cancelled task resumes after its
        // replacement is already stored, so clearing from inside the task would drop the new
        // handle and make the next refresh uncancellable. Cancelling a finished task is a no-op,
        // and the table is bounded by the number of configured providers.
        refreshTasks[providerID] = Task { [weak self] in
            guard let self, let config = self.customProvider(id: providerID) else { return }
            do {
                let models = try await CustomProviderModelDiscovery.discoverModels(
                    endpointURL: config.endpointURL,
                    apiFormat: config.apiFormat,
                    apiKey: self.loadAPIKey(for: config)
                )
                guard !Task.isCancelled else { return }
                self.updateDiscoveredModels(for: providerID, models: models)
            } catch {
                let name = config.name
                let reason = error.localizedDescription
                Self.logger.warning("Model discovery failed for \(name): \(reason)")
            }
        }
    }

    /// Update discovered models for a provider.
    /// Persists without a blanket notification; posts only if the discovery
    /// refresh actually removed the currently-selected model from the
    /// available-model catalog. Active sessions then rebuild via
    /// `validatedSelectedModelID`. Uninvolved sessions are not disturbed.
    func updateDiscoveredModels(for providerId: UUID, models: [AIProviderModel]) {
        guard var provider = customProvider(id: providerId) else { return }
        provider.discoveredModels = models
        provider.lastModelRefresh = Date()
        updateCustomProviderSilently(provider)
        postCredentialsChangedIfSelectionInvalidated()
        Self.logger.debug("Updated \(models.count) discovered models for provider: \(provider.name)")
    }

    /// Add a manual model to a custom provider.
    /// The active selection cannot be invalidated by an add — even the
    /// shadow-remove of an existing entry is followed by re-adding the same
    /// ID, so no notification is needed here.
    func addManualModel(to providerId: UUID, id: String, displayName: String) {
        guard var provider = customProvider(id: providerId) else { return }
        provider.manualModels.removeAll { $0.id == id }
        provider.discoveredModels.removeAll { $0.id == id }
        provider.manualModels.append(AIProviderModel.manualModel(id: id, displayName: displayName))
        updateCustomProviderSilently(provider)
    }

    /// Remove a manually-added model from a custom provider.
    /// Discovered models aren't user-removable — they come from the endpoint
    /// and would repopulate on the next refresh.
    /// Posts `.aiCredentialsChanged` only if the removed model was the active
    /// selection, so an active session promptly rebuilds its provider via
    /// `validatedSelectedModelID`'s auto-correction instead of continuing to
    /// send requests for a model the user just removed. Other sessions are
    /// not disturbed.
    func removeModel(from providerId: UUID, modelId: String) {
        guard var provider = customProvider(id: providerId) else { return }
        provider.manualModels.removeAll { $0.id == modelId }
        // Manual-model overrides are orphaned once the model is gone. Discovered
        // models can churn across refreshes, so their overrides are kept.
        provider.contextWindowOverrides.removeValue(forKey: modelId)
        updateCustomProviderSilently(provider)
        postCredentialsChangedIfSelectionInvalidated()
    }

    /// Set or clear a user-provided context window size for a custom model.
    /// Pass `nil` (or 0) to clear. Uses the silent-update path — the override
    /// is user-visible metadata that doesn't invalidate credentials or the
    /// active selection.
    func setContextWindowOverride(_ tokens: Int?, for modelId: String, in providerId: UUID) {
        guard var provider = customProvider(id: providerId) else { return }
        if let tokens, tokens > 0 {
            provider.contextWindowOverrides[modelId] = tokens
        } else {
            provider.contextWindowOverrides.removeValue(forKey: modelId)
        }
        updateCustomProviderSilently(provider)
    }

    /// Retrieve the user-provided context window size for a custom model, or nil.
    func contextWindowOverride(for modelId: String, in providerId: UUID) -> Int? {
        customProvider(id: providerId)?.contextWindowOverrides[modelId]
    }

    /// Update a custom provider without posting `.aiCredentialsChanged`.
    /// Reserved for internal mutations (discovery refresh, manual model
    /// add/remove) that don't change credentials or the provider's config
    /// (endpoint, API key, API format, display name) — just its cached
    /// model list. Writing to `_customProviders` directly still triggers
    /// `@Observable` so the Settings UI refreshes.
    private func updateCustomProviderSilently(_ config: CustomProviderConfig) {
        var providers = _customProviders
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        providers[index] = config
        _customProviders = providers
        if let data = try? JSONEncoder().encode(providers) {
            SettingsStore.shared.set(Settings.AI.customProviders, data)
        }
    }

    /// Post `.aiCredentialsChanged` only if the currently selected model is
    /// no longer in `allAvailableModels`. Used after silent model-list
    /// mutations — discovery refresh can drop a server-side-retired model
    /// and manual removal can delete the active selection; both cases must
    /// invalidate a live session's cached provider so it doesn't keep
    /// sending requests for a model the user removed.
    private func postCredentialsChangedIfSelectionInvalidated() {
        let selection = _globalSelectedModelID
        guard !selection.isEmpty else { return }
        if !allAvailableModels.contains(where: { $0.id == selection }) {
            NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
        }
    }

    /// Persist custom providers to UserDefaults
    private func saveCustomProviders() {
        let providers = _customProviders
        if let data = try? JSONEncoder().encode(providers) {
            SettingsStore.shared.set(Settings.AI.customProviders, data)
            let count = providers.count
            Self.logger.debug("Saved \(count) custom providers")
        }
        NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
    }

    /// Gets all available models from all configured providers
    var allAvailableModels: [AIProviderModel] {
        var models: [AIProviderModel] = []

        // The OpenAI slot serves either the API-key lineup or the ChatGPT
        // subscription's discovered lineup — the auth modes are exclusive.
        switch _openAIAuthMode {
        case .apiKey:
            if hasAPIKey(for: OpenAIProvider.providerID) {
                models.append(contentsOf: AIProviderModel.openAIModels)
            }
        case .chatgptSignIn:
            if _isChatGPTSignedIn {
                models.append(contentsOf: ChatGPTModelStore.shared.providerModels)
            }
        }

        // Anthropic models (if configured)
        if hasAnthropicAPIKey {
            models.append(contentsOf: AIProviderModel.anthropicModels)
        }

        // Bedrock models (if a Cloud account is linked)
        if hasBedrockConfigured {
            models.append(contentsOf: AIProviderModel.bedrockModels)
        }

        // Google models (if configured)
        if hasGoogleAPIKey {
            models.append(contentsOf: AIProviderModel.googleModels)
        }

        // OpenRouter FAVORITES only (not the full 400+ model catalog)
        if hasOpenRouterAPIKey {
            models.append(contentsOf: openRouterFavoriteModels)
        }

        // Custom provider models. No API-key requirement: local servers are routinely
        // unauthenticated, and gating on a key made them vanish from the picker while
        // `validatedSelectedModelID` silently re-pointed the selection elsewhere.
        for provider in customProviders where provider.isEnabled {
            models.append(contentsOf: provider.allModels)
        }

        return models
    }

    /// Finds a custom model by ID across all custom providers
    func findCustomModel(id: String) -> AIProviderModel? {
        for provider in customProviders {
            if let model = provider.allModels.first(where: { $0.id == id }) {
                return model
            }
        }
        return nil
    }

    /// Gets the custom provider that owns a specific model
    func customProvider(for modelId: String) -> CustomProviderConfig? {
        for provider in customProviders {
            if provider.allModels.contains(where: { $0.id == modelId }) {
                return provider
            }
        }
        return nil
    }

    /// Returns whether streaming is enabled for a custom model
    func isStreamingEnabled(for modelId: String) -> Bool {
        guard let provider = customProvider(for: modelId) else {
            return true // Default to streaming enabled
        }
        return provider.useStreaming
    }

    /// Returns whether Responses API should be used for a custom model
    func usesResponsesAPI(for modelId: String) -> Bool {
        guard let provider = customProvider(for: modelId) else {
            return true // Default to Responses API
        }
        return provider.apiFormat == .openAIResponses
    }

    // MARK: - ChatGPT Subscription

    /// Which auth path the OpenAI slot uses. Flipping posts
    /// `.aiCredentialsChanged` so live sessions swap providers.
    var openAIAuthMode: OpenAIAuthMode {
        get { _openAIAuthMode }
        set {
            guard newValue != _openAIAuthMode else { return }
            _openAIAuthMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: openAIAuthModeKey)
            NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
        }
    }

    /// Whether a ChatGPT subscription credential is stored.
    var hasChatGPTSignIn: Bool {
        _isChatGPTSignedIn
    }

    /// Called by the sign-in/out flows after the credential store is updated.
    /// Flag first, then notification, mirroring the Anthropic save ordering so
    /// observers never read stale state.
    func setChatGPTSignedIn(_ signedIn: Bool) {
        _isChatGPTSignedIn = signedIn
        NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
    }

    /// Mode-aware "is the OpenAI slot usable" check for settings rows.
    var hasOpenAIProviderConfigured: Bool {
        switch _openAIAuthMode {
        case .apiKey: return hasAPIKey(for: OpenAIProvider.providerID)
        case .chatgptSignIn: return _isChatGPTSignedIn
        }
    }

    // MARK: - Anthropic API Key Storage

    /// Saves the API key for Anthropic.
    /// Flips the cached `_hasAnthropicAPIKey` flag BEFORE the keychain write,
    /// because `saveAPIKey` posts `.aiCredentialsChanged` synchronously; any
    /// observer that reads `hasAnthropicAPIKey` or `allAvailableModels`
    /// immediately after would otherwise see stale state and, for a just-added
    /// key, miss the new provider. Reverts on keychain failure.
    func saveAnthropicAPIKey(_ apiKey: String, syncToiCloud: Bool = true) throws {
        let previous = _hasAnthropicAPIKey
        _hasAnthropicAPIKey = true
        do {
            try saveAPIKey(apiKey, for: anthropicAccount, syncToiCloud: syncToiCloud)
        } catch {
            _hasAnthropicAPIKey = previous
            throw error
        }
    }

    /// Loads the API key for Anthropic
    func loadAnthropicAPIKey() -> String? {
        loadAPIKey(for: anthropicAccount)
    }

    /// Deletes the API key for Anthropic.
    /// Flips the cached flag BEFORE the keychain delete so observers of the
    /// resulting `.aiCredentialsChanged` see the key as absent. Without this,
    /// `validatedSelectedModelID` could keep the session pinned to an
    /// Anthropic model even though its key was just removed, and the rebuild
    /// would fall into the "not configured" branch instead of switching to
    /// another configured provider.
    func deleteAnthropicAPIKey() throws {
        let previous = _hasAnthropicAPIKey
        _hasAnthropicAPIKey = false
        do {
            try deleteAPIKey(for: anthropicAccount)
        } catch {
            _hasAnthropicAPIKey = previous
            throw error
        }
    }

    /// Whether Anthropic has an API key configured
    var hasAnthropicAPIKey: Bool {
        _hasAnthropicAPIKey
    }

    // MARK: - Google API Key Storage

    /// Saves the API key for Google Gemini.
    /// See `saveAnthropicAPIKey` for the flag-before-keychain ordering rationale.
    func saveGoogleAPIKey(_ apiKey: String, syncToiCloud: Bool = true) throws {
        let previous = _hasGoogleAPIKey
        _hasGoogleAPIKey = true
        do {
            try saveAPIKey(apiKey, for: googleAccount, syncToiCloud: syncToiCloud)
        } catch {
            _hasGoogleAPIKey = previous
            throw error
        }
    }

    /// Loads the API key for Google Gemini
    func loadGoogleAPIKey() -> String? {
        loadAPIKey(for: googleAccount)
    }

    /// Deletes the API key for Google Gemini.
    /// See `deleteAnthropicAPIKey` for the flag-before-keychain ordering rationale.
    func deleteGoogleAPIKey() throws {
        let previous = _hasGoogleAPIKey
        _hasGoogleAPIKey = false
        do {
            try deleteAPIKey(for: googleAccount)
        } catch {
            _hasGoogleAPIKey = previous
            throw error
        }
    }

    /// Whether Google has an API key configured
    var hasGoogleAPIKey: Bool {
        _hasGoogleAPIKey
    }

    // MARK: - OpenRouter API Key Storage

    /// Saves the API key for OpenRouter.
    /// See `saveAnthropicAPIKey` for the flag-before-keychain ordering rationale.
    func saveOpenRouterAPIKey(_ apiKey: String, syncToiCloud: Bool = true) throws {
        let previous = _hasOpenRouterAPIKey
        _hasOpenRouterAPIKey = true
        do {
            try saveAPIKey(apiKey, for: openRouterAccount, syncToiCloud: syncToiCloud)
        } catch {
            _hasOpenRouterAPIKey = previous
            throw error
        }
    }

    /// Loads the API key for OpenRouter
    func loadOpenRouterAPIKey() -> String? {
        loadAPIKey(for: openRouterAccount)
    }

    /// Deletes the API key for OpenRouter.
    /// Clears the cached flag plus favorites and discovered models BEFORE the
    /// keychain delete. `saveAPIKey`/`deleteAPIKey` post `.aiCredentialsChanged`
    /// synchronously, and `allAvailableModels` uses both `hasOpenRouterAPIKey`
    /// and the favorites list — so observers must see all of that state as
    /// cleared, otherwise they'd keep the session pinned to an OpenRouter
    /// model and then get a nil provider from the factory (since the keychain
    /// key is gone). Reverts all state on keychain failure.
    func deleteOpenRouterAPIKey() throws {
        let previousFlag = _hasOpenRouterAPIKey
        let previousFavorites = _openRouterFavoriteModelIDs
        let previousDiscovered = _openRouterDiscoveredModels

        _hasOpenRouterAPIKey = false
        _openRouterFavoriteModelIDs.removeAll()
        _openRouterDiscoveredModels.removeAll()
        SettingsStore.shared.reset(Settings.AI.openRouterFavorites)
        UserDefaults.standard.removeObject(forKey: openRouterModelsKey)

        do {
            try deleteAPIKey(for: openRouterAccount)
        } catch {
            _hasOpenRouterAPIKey = previousFlag
            _openRouterFavoriteModelIDs = previousFavorites
            _openRouterDiscoveredModels = previousDiscovered
            SettingsStore.shared.set(Settings.AI.openRouterFavorites, Array(previousFavorites))
            if let data = try? JSONEncoder().encode(previousDiscovered) {
                UserDefaults.standard.set(data, forKey: openRouterModelsKey)
            }
            throw error
        }
    }

    /// Whether OpenRouter has an API key configured
    var hasOpenRouterAPIKey: Bool {
        _hasOpenRouterAPIKey
    }

    // MARK: - Bedrock Configuration

    /// Linked AWS Cloud account ID for the Bedrock provider, or nil if Bedrock isn't configured.
    /// Setting to nil clears the linkage; the actual AWS credentials remain in the
    /// Cloud account's Keychain record (Bedrock just unbinds from them).
    var bedrockCloudAccountID: UUID? {
        get { _bedrockCloudAccountID }
        set {
            _bedrockCloudAccountID = newValue
            if let uuid = newValue {
                UserDefaults.standard.set(uuid.uuidString, forKey: bedrockCloudAccountIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: bedrockCloudAccountIDKey)
            }
            // Tell active sessions to rebuild their providers — the Bedrock
            // model the session is pinned to may now be unavailable.
            NotificationCenter.default.post(name: .aiCredentialsChanged, object: self)
        }
    }

    /// Region that Bedrock invocations are routed to. Stored independently of
    /// the linked AWS account's region so the user can pick any Bedrock-supported
    /// region regardless of where their broader AWS account is anchored.
    var bedrockRegion: String {
        get { _bedrockRegion }
        set {
            let normalized = BedrockRegions.isSupported(newValue) ? newValue : BedrockRegions.defaultRegion
            _bedrockRegion = normalized
            SettingsStore.shared.set(Settings.AI.bedrockRegion, normalized)
        }
    }

    /// Whether the user has linked a Cloud account to Bedrock. The deeper
    /// validation (account still exists, is AWS-typed, region is valid) lives
    /// on `BedrockProvider.isConfigured` and is checked at request time.
    var hasBedrockConfigured: Bool {
        _bedrockCloudAccountID != nil
    }

    // MARK: - OpenRouter Favorites

    /// OpenRouter favorite model IDs (only these appear in main model picker)
    var openRouterFavoriteModelIDs: Set<String> {
        get { _openRouterFavoriteModelIDs }
        set {
            _openRouterFavoriteModelIDs = newValue
            SettingsStore.shared.set(Settings.AI.openRouterFavorites, Array(newValue))
            Self.logger.debug("Saved \(newValue.count) OpenRouter favorites")
        }
    }

    /// Add a model to OpenRouter favorites
    func addOpenRouterFavorite(_ modelID: String) {
        _openRouterFavoriteModelIDs.insert(modelID)
        SettingsStore.shared.set(Settings.AI.openRouterFavorites, Array(_openRouterFavoriteModelIDs))
        Self.logger.debug("Added OpenRouter favorite: \(modelID)")
    }

    /// Remove a model from OpenRouter favorites
    func removeOpenRouterFavorite(_ modelID: String) {
        _openRouterFavoriteModelIDs.remove(modelID)
        SettingsStore.shared.set(Settings.AI.openRouterFavorites, Array(_openRouterFavoriteModelIDs))
        Self.logger.debug("Removed OpenRouter favorite: \(modelID)")
    }

    /// Check if a model is in OpenRouter favorites
    func isOpenRouterFavorite(_ modelID: String) -> Bool {
        _openRouterFavoriteModelIDs.contains(modelID)
    }

    /// Get favorite models filtered from discovered models
    var openRouterFavoriteModels: [AIProviderModel] {
        _openRouterDiscoveredModels.filter { _openRouterFavoriteModelIDs.contains($0.id) }
    }

    // MARK: - OpenRouter Discovered Models

    /// Full catalog of discovered OpenRouter models
    var openRouterDiscoveredModels: [AIProviderModel] {
        get { _openRouterDiscoveredModels }
        set {
            _openRouterDiscoveredModels = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: openRouterModelsKey)
                Self.logger.debug("Saved \(newValue.count) discovered OpenRouter models")
            }
        }
    }

    /// Update discovered models from API response
    func updateOpenRouterDiscoveredModels(_ models: [AIProviderModel]) {
        openRouterDiscoveredModels = models
    }

    /// Find an OpenRouter model by ID
    func findOpenRouterModel(id: String) -> AIProviderModel? {
        _openRouterDiscoveredModels.first { $0.id == id }
    }

    /// Get unique provider slugs from discovered models (for filtering UI)
    var openRouterProviderSlugs: [String] {
        let slugs = Set(_openRouterDiscoveredModels.compactMap { AIProviderModel.openRouterProviderSlug(for: $0.id) })
        return slugs.sorted()
    }

    // MARK: - Command Approval Mode

    /// Command approval mode for AI Agent
    var approvalMode: CommandApprovalMode {
        get { _approvalMode }
        set {
            _approvalMode = newValue
            SettingsStore.shared.set(Settings.AI.approvalMode, newValue)
            Self.logger.debug("Approval mode: \(newValue.rawValue)")
        }
    }

    /// Convenience: whether YOLO mode is enabled (for backwards compatibility)
    var yoloModeEnabled: Bool {
        _approvalMode == .yolo
    }

    // MARK: - Web Search Settings

    /// Whether web search is enabled for AI Agent
    var webSearchEnabled: Bool {
        get { _webSearchEnabled }
        set {
            _webSearchEnabled = newValue
            SettingsStore.shared.set(Settings.AI.webSearchEnabled, newValue)
            Self.logger.debug("Web search enabled: \(newValue)")
        }
    }

    /// Default search engine for AI Agent
    var defaultSearchEngine: SearchEngine {
        get { SearchEngine(rawValue: _defaultSearchEngine) ?? .duckduckgo }
        set {
            _defaultSearchEngine = newValue.rawValue
            SettingsStore.shared.set(Settings.AI.webSearchEngine, newValue)
            Self.logger.debug("Default search engine: \(newValue.rawValue)")
        }
    }

    // MARK: - AI Commit Message Setting

    /// Whether AI-generated commit messages are enabled for git commit
    var aiCommitMessageEnabled: Bool {
        get { _aiCommitMessageEnabled }
        set {
            _aiCommitMessageEnabled = newValue
            SettingsStore.shared.set(Settings.AI.commitMessageEnabled, newValue)
        }
    }

    /// Model ID selected for AI commit messages (empty = not configured)
    var aiCommitMessageModelID: String {
        get { _aiCommitMessageModelID }
        set {
            _aiCommitMessageModelID = newValue
            SettingsStore.shared.set(Settings.AI.commitMessageModel, newValue)
        }
    }

    // MARK: - AI Agent Presentation Mode

    /// AI Agent presentation mode (sidebar or window) - iPad/Mac Catalyst only
    var aiAgentPresentationMode: AIAgentPresentationMode {
        get { _aiAgentPresentationMode }
        set {
            _aiAgentPresentationMode = newValue
            SettingsStore.shared.set(Settings.AI.presentationMode, newValue)
            Self.logger.debug("AI Agent presentation mode: \(newValue.rawValue)")
        }
    }

    /// Sidebar width for AI Agent in sidebar mode (persisted)
    var aiAgentSidebarWidth: CGFloat {
        get { _aiAgentSidebarWidth }
        set {
            let clampedWidth = max(280, newValue)  // Minimum 280
            _aiAgentSidebarWidth = clampedWidth
            SettingsStore.shared.set(Settings.AI.sidebarWidth, Double(clampedWidth))
        }
    }

    // MARK: - Temperature Settings

    /// Default temperatures per provider (matches existing hardcoded values)
    static let defaultTemperatures: [String: Double] = [
        OpenAIProvider.providerID: 0.4,
        AnthropicProvider.providerID: 0.4,
        BedrockProvider.providerID: 0.4,
        GeminiProvider.providerID: 0.4,
        OpenRouterProvider.providerID: 0.4
    ]

    /// Default temperature for custom providers
    static let defaultCustomProviderTemperature: Double = 0.4

    /// Get user-configured temperature for a built-in provider
    /// - Parameter providerID: The provider identifier (e.g., "openai", "anthropic")
    /// - Returns: User-set temperature, or nil to use provider default
    func temperature(for providerID: String) -> Double? {
        let key = "\(temperatureKeyPrefix).\(providerID)"
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return nil  // Not set - use provider default
        }
        return UserDefaults.standard.double(forKey: key)
    }

    /// Set temperature for a built-in provider
    /// - Parameters:
    ///   - temperature: The temperature value (nil to reset to default)
    ///   - providerID: The provider identifier
    func setTemperature(_ temperature: Double?, for providerID: String) {
        let key = "\(temperatureKeyPrefix).\(providerID)"
        if let temp = temperature {
            UserDefaults.standard.set(temp, forKey: key)
            Self.logger.debug("Set temperature for \(providerID): \(temp)")
        } else {
            UserDefaults.standard.removeObject(forKey: key)
            Self.logger.debug("Reset temperature for \(providerID) to default")
        }
    }

    /// Get user-configured temperature for a custom provider
    /// - Parameter customProviderID: The custom provider UUID
    /// - Returns: User-set temperature, or nil to use default
    func temperature(for customProviderID: UUID) -> Double? {
        let key = "\(temperatureKeyPrefix).custom.\(customProviderID.uuidString)"
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return nil
        }
        return UserDefaults.standard.double(forKey: key)
    }

    /// Set temperature for a custom provider
    /// - Parameters:
    ///   - temperature: The temperature value (nil to reset to default)
    ///   - customProviderID: The custom provider UUID
    func setTemperature(_ temperature: Double?, for customProviderID: UUID) {
        let key = "\(temperatureKeyPrefix).custom.\(customProviderID.uuidString)"
        if let temp = temperature {
            UserDefaults.standard.set(temp, forKey: key)
            Self.logger.debug("Set temperature for custom provider \(customProviderID): \(temp)")
        } else {
            UserDefaults.standard.removeObject(forKey: key)
            Self.logger.debug("Reset temperature for custom provider \(customProviderID) to default")
        }
    }

    /// Get effective temperature for a built-in provider (user setting or default)
    /// - Parameters:
    ///   - providerID: The provider identifier
    ///   - supportsTemperature: Whether the current model supports temperature
    /// - Returns: The temperature to use, or nil if not supported
    func effectiveTemperature(for providerID: String, supportsTemperature: Bool) -> Double? {
        guard supportsTemperature else { return nil }
        if let userTemp = temperature(for: providerID) {
            return userTemp
        }
        return Self.defaultTemperatures[providerID]
    }

    /// Get effective temperature for a custom provider (user setting or default)
    /// - Parameters:
    ///   - customProviderID: The custom provider UUID
    ///   - supportsTemperature: Whether the current model supports temperature
    /// - Returns: The temperature to use, or nil if not supported
    func effectiveTemperature(for customProviderID: UUID, supportsTemperature: Bool) -> Double? {
        guard supportsTemperature else { return nil }
        if let userTemp = temperature(for: customProviderID) {
            return userTemp
        }
        return Self.defaultCustomProviderTemperature
    }

    // MARK: - Provider Factory

    /// Create the appropriate provider for any model ID.
    /// Checks custom providers, then Anthropic, Google, OpenRouter, OpenAI.
    func createProvider(forModelID modelID: String) -> (any AIProvider)? {
        // Check if this model belongs to any custom provider
        for provider in customProviders where provider.isEnabled {
            if provider.allModels.contains(where: { $0.id == modelID }) {
                return createCustomProvider(config: provider, modelID: modelID)
            }
        }

        // Check if this is an Anthropic model
        if AIProviderModel.anthropicModel(id: modelID) != nil {
            guard let apiKey = loadAnthropicAPIKey() else { return nil }
            return AnthropicProvider(apiKey: apiKey, selectedModelID: modelID)
        }

        // Check if this is a Bedrock model (Anthropic models served via AWS Bedrock).
        // Internal IDs are prefixed with `bedrock-` to disambiguate from the
        // direct-API Anthropic IDs above; `bedrockModel(id:)` only matches the
        // prefixed form so this check can't fight with the Anthropic branch.
        if AIProviderModel.bedrockModel(id: modelID) != nil {
            return createBedrockProvider(forModelID: modelID)
        }

        // Check if this is a Google model
        if AIProviderModel.googleModel(id: modelID) != nil {
            guard let apiKey = loadGoogleAPIKey() else { return nil }
            return GeminiProvider(apiKey: apiKey, selectedModelID: modelID)
        }

        // Check if this is an OpenRouter model
        if openRouterDiscoveredModels.contains(where: { $0.id == modelID }) {
            guard let apiKey = loadOpenRouterAPIKey() else { return nil }
            return OpenRouterProvider(apiKey: apiKey, selectedModelID: modelID)
        }

        // In ChatGPT-subscription mode the subscription owns the OpenAI slot
        // entirely; a stale stored API key must not silently take over.
        if _openAIAuthMode == .chatgptSignIn {
            guard _isChatGPTSignedIn else { return nil }
            return ChatGPTProvider(selectedModelID: modelID)
        }

        // Default to OpenAI
        guard let apiKey = loadAPIKey(for: OpenAIProvider.providerID) else { return nil }
        return OpenAIProvider(apiKey: apiKey, selectedModelID: modelID)
    }

    // MARK: - Private Keychain Helpers

    private func saveToKeychain(_ data: Data, account: String, storageLevel: KeyStorageLevel) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: AppIdentifiers.keychainAccessGroup
        ]

        switch storageLevel {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable as String] = false
        case .backupOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = false
        case .iCloudSync:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecAttrSynchronizable as String] = true
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status != errSecDuplicateItem else {
            throw KeychainManager.KeychainError.duplicateItem
        }

        guard status == errSecSuccess else {
            throw KeychainManager.KeychainError.unexpectedStatus(status)
        }
    }

    private func loadFromKeychain(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: AppIdentifiers.keychainAccessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainManager.KeychainError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainManager.KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainManager.KeychainError.dataConversionFailed
        }

        return data
    }

    private func deleteFromKeychain(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppIdentifiers.keychainAccessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainManager.KeychainError.unexpectedStatus(status)
        }
    }

    private func listKeychainAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: AppIdentifiers.keychainAccessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            item[kSecAttrAccount as String] as? String
        }
    }
}
#endif
