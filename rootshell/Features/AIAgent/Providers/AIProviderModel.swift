#if !CHINA_BUILD
//
//  AIProviderModel.swift
//  rootshell
//
//  Model definitions for AI providers
//

import Foundation

/// Represents an AI model available from a provider
struct AIProviderModel: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let displayName: String
    let description: String
    let tier: ModelTier
    let supportsTools: Bool
    let supportsTemperature: Bool
    let supportsThinking: Bool  // Extended thinking mode (Anthropic Claude 4+)
    let source: ModelSource
    let maxCompletionTokens: Int?  // nil = use tier default
    let contextWindowTokens: Int?  // Total input+output context capacity; nil = unknown

    /// Model pricing/capability tiers
    enum ModelTier: String, Codable, Sendable {
        case budget    // Fastest, lowest cost
        case standard  // Best balance (default)
        case premium   // Most capable
        case reasoning // Deep reasoning models
    }

    /// Where the model configuration came from
    enum ModelSource: String, Codable, Sendable {
        case openAI         // Built-in OpenAI models
        case chatGPT        // ChatGPT plan models (from the signed-in account's catalog)
        case anthropic      // Built-in Anthropic models
        case bedrock        // Anthropic models served via AWS Bedrock
        case google         // Built-in Google Gemini models
        case openRouter     // OpenRouter models (discovered from API)
        case customEndpoint // Discovered from custom endpoint
        case manual         // Manually entered by user
    }

    /// Create a copy with a different source
    func withSource(_ newSource: ModelSource) -> AIProviderModel {
        AIProviderModel(
            id: id,
            displayName: displayName,
            description: description,
            tier: tier,
            supportsTools: supportsTools,
            supportsTemperature: supportsTemperature,
            supportsThinking: supportsThinking,
            source: newSource,
            maxCompletionTokens: maxCompletionTokens,
            contextWindowTokens: contextWindowTokens
        )
    }

    /// Create a copy with a different context window size
    func withContextWindowTokens(_ tokens: Int?) -> AIProviderModel {
        AIProviderModel(
            id: id,
            displayName: displayName,
            description: description,
            tier: tier,
            supportsTools: supportsTools,
            supportsTemperature: supportsTemperature,
            supportsThinking: supportsThinking,
            source: source,
            maxCompletionTokens: maxCompletionTokens,
            contextWindowTokens: tokens
        )
    }

    /// Effective max completion tokens - uses explicit value or tier-based default
    var effectiveMaxCompletionTokens: Int {
        if let explicit = maxCompletionTokens {
            return explicit
        }
        return tier.defaultMaxCompletionTokens
    }
}

// MARK: - OpenAI Models

extension AIProviderModel {
    /// Available OpenAI models
    static let openAIModels: [AIProviderModel] = [
        // Premium tier - GPT-6 flagship (recommended default)
        .init(
            id: "gpt-6-astra",
            displayName: "GPT-6 Astra",
            description: "Most intelligent, state-of-the-art (Recommended)",
            tier: .premium,
            supportsTools: true,
            supportsTemperature: false,  // GPT-6 rejects temperature when reasoning is on
            supportsThinking: false,
            source: .openAI,
            maxCompletionTokens: 128_000,
            contextWindowTokens: 1_050_000
        ),

        // Standard tier - balanced intelligence and cost
        .init(
            id: "gpt-6-sol",
            displayName: "GPT-6 Sol",
            description: "Strong reasoning for coding and agentic work",
            tier: .standard,
            supportsTools: true,
            supportsTemperature: false,
            supportsThinking: false,
            source: .openAI,
            maxCompletionTokens: 128_000,
            contextWindowTokens: 1_050_000
        ),

        // Budget tier - cost-sensitive, high-volume workloads
        .init(
            id: "gpt-6-luna",
            displayName: "GPT-6 Luna",
            description: "Efficient, repeatable work at scale",
            tier: .budget,
            supportsTools: true,
            supportsTemperature: false,
            supportsThinking: false,
            source: .openAI,
            maxCompletionTokens: 128_000,
            contextWindowTokens: 1_050_000
        ),
    ]

    /// Default model ID for new configurations
    nonisolated static let defaultModelID = "gpt-6-astra"

    /// Get model by ID
    static func openAIModel(id: String) -> AIProviderModel? {
        openAIModels.first { $0.id == id }
    }

    /// Get default model
    static var defaultModel: AIProviderModel {
        openAIModel(id: defaultModelID) ?? openAIModels[0]
    }

    /// Models grouped by tier for UI display
    static var openAIModelsByTier: [ModelTier: [AIProviderModel]] {
        Dictionary(grouping: openAIModels, by: { $0.tier })
    }
}

// MARK: - Model Tier Display

extension AIProviderModel.ModelTier {
    var displayName: String {
        switch self {
        case .budget: return "Budget"
        case .standard: return "Standard"
        case .premium: return "Premium"
        case .reasoning: return "Reasoning"
        }
    }

    var sortOrder: Int {
        switch self {
        case .standard: return 0  // Show first (recommended)
        case .budget: return 1
        case .premium: return 2
        case .reasoning: return 3
        }
    }

    /// Default max completion tokens for each tier
    var defaultMaxCompletionTokens: Int {
        switch self {
        case .budget: return 24048
        case .standard: return 44096
        case .premium: return 48192
        case .reasoning: return 56384  // Reasoning models need more space to think
        }
    }
}

// MARK: - Model Source Display

extension AIProviderModel.ModelSource {
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .chatGPT: return "ChatGPT"
        case .anthropic: return "Anthropic"
        case .bedrock: return "AWS Bedrock"
        case .google: return "Google"
        case .openRouter: return "OpenRouter"
        case .customEndpoint: return "Custom"
        case .manual: return "Custom"
        }
    }

    var sortOrder: Int {
        switch self {
        case .openAI: return 0
        case .chatGPT: return 1
        case .anthropic: return 2
        case .bedrock: return 3
        case .google: return 4
        case .openRouter: return 5
        case .customEndpoint: return 6
        case .manual: return 7
        }
    }
}

// MARK: - Anthropic Models

extension AIProviderModel {
    /// Available Anthropic models
    static let anthropicModels: [AIProviderModel] = [
        // Premium tier - Claude Fable 5.2, thinking always on (1M context)
        .init(
            id: "claude-fable-5-2",
            displayName: "Claude Fable 5.2",
            description: "Most capable, for the hardest long-running work",
            tier: .premium,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .anthropic,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_000_000
        ),

        // Premium tier - Claude Opus 5.5, thinking always on (1M context)
        .init(
            id: "claude-opus-5-5",
            displayName: "Claude Opus 5.5",
            description: "Frontier Opus, 1M context, adaptive thinking",
            tier: .premium,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .anthropic,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_000_000
        ),

        // Standard tier - Claude Sonnet 5.5 with adaptive thinking
        .init(
            id: "claude-sonnet-5-5",
            displayName: "Claude Sonnet 5.5",
            description: "Near-Opus quality, fast & capable, adaptive thinking",
            tier: .standard,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .anthropic,
            maxCompletionTokens: 64_000,
            contextWindowTokens: 1_000_000
        ),

        // Budget tier - Claude Haiku 5.5 with adaptive thinking
        .init(
            id: "claude-haiku-5-5",
            displayName: "Claude Haiku 5.5",
            description: "Fastest, lowest cost",
            tier: .budget,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .anthropic,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_000_000
        ),
    ]

    /// Default Anthropic model ID
    static let defaultAnthropicModelID = "claude-sonnet-5-5"

    /// Get Anthropic model by ID
    static func anthropicModel(id: String) -> AIProviderModel? {
        anthropicModels.first { $0.id == id }
    }

    /// Anthropic models grouped by tier for UI display
    static var anthropicModelsByTier: [ModelTier: [AIProviderModel]] {
        Dictionary(grouping: anthropicModels, by: { $0.tier })
    }
}

// MARK: - Bedrock Models

extension AIProviderModel {
    /// Anthropic Claude models served via AWS Bedrock.
    ///
    /// IDs are prefixed with `bedrock-` so the global model picker can show
    /// both the direct-API and Bedrock entries side by side without colliding.
    /// Capabilities mirror the corresponding direct-API entries because the
    /// underlying model is the same — only the transport differs.
    static let bedrockModels: [AIProviderModel] = [
        .init(
            id: "bedrock-claude-fable-5-2",
            displayName: "Claude Fable 5.2 (Bedrock)",
            description: "Most capable, for the hardest long-running work",
            tier: .premium,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .bedrock,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_000_000
        ),
        .init(
            id: "bedrock-claude-opus-5-5",
            displayName: "Claude Opus 5.5 (Bedrock)",
            description: "Frontier Opus, 1M context, adaptive thinking",
            tier: .premium,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .bedrock,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_000_000
        ),
        .init(
            id: "bedrock-claude-sonnet-5-5",
            displayName: "Claude Sonnet 5.5 (Bedrock)",
            description: "Near-Opus quality, fast & capable, adaptive thinking",
            tier: .standard,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .bedrock,
            maxCompletionTokens: 64_000,
            contextWindowTokens: 1_000_000
        ),
        .init(
            id: "bedrock-claude-haiku-5-5",
            displayName: "Claude Haiku 5.5 (Bedrock)",
            description: "Fastest, lowest cost",
            tier: .budget,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .bedrock,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_000_000
        )
    ]

    /// Default Bedrock model when the user first configures the provider.
    static let defaultBedrockModelID = "bedrock-claude-sonnet-5-5"

    /// Get a Bedrock model entry by internal ID.
    static func bedrockModel(id: String) -> AIProviderModel? {
        bedrockModels.first { $0.id == id }
    }
}

// MARK: - Google Models

extension AIProviderModel {
    /// Available Google Gemini models
    static let googleModels: [AIProviderModel] = [
        // Budget tier - Gemini 3.1 Flash Lite (preview)
        .init(
            id: "gemini-3.1-flash-lite-preview",
            displayName: "Gemini 3.1 Flash Lite",
            description: "Fastest, most cost-efficient",
            tier: .budget,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .google,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_048_576
        ),

        // Budget tier - Gemini 2.5 Flash
        .init(
            id: "gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            description: "Fast & cost-effective",
            tier: .budget,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: false,
            source: .google,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_048_576
        ),

        // Standard tier - Gemini 3.0 Flash (preview)
        .init(
            id: "gemini-3-flash-preview",
            displayName: "Gemini 3.0 Flash",
            description: "Fast next-gen model",
            tier: .standard,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .google,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_048_576
        ),

        // Standard tier - Gemini 2.5 Pro (recommended)
        .init(
            id: "gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            description: "Best balance, adaptive thinking",
            tier: .standard,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .google,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_048_576
        ),

        // Premium tier - Gemini 3.1 Pro
        .init(
            id: "gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro",
            description: "Most capable, reasoning-first",
            tier: .premium,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: true,
            source: .google,
            maxCompletionTokens: nil,
            contextWindowTokens: 1_048_576
        ),
    ]

    /// Default Google model ID
    static let defaultGoogleModelID = "gemini-2.5-pro"

    /// Get Google model by ID
    static func googleModel(id: String) -> AIProviderModel? {
        googleModels.first { $0.id == id }
    }

    /// Google models grouped by tier for UI display
    static var googleModelsByTier: [ModelTier: [AIProviderModel]] {
        Dictionary(grouping: googleModels, by: { $0.tier })
    }
}

// MARK: - Custom Endpoint Models

extension AIProviderModel {
    /// Create a model from a custom endpoint discovery
    static func customEndpointModel(
        id: String,
        displayName: String? = nil,
        maxCompletionTokens: Int? = nil,
        contextWindowTokens: Int? = nil
    ) -> AIProviderModel {
        AIProviderModel(
            id: id,
            displayName: displayName ?? id,
            description: "Custom endpoint model",
            tier: .standard,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: false,
            source: .customEndpoint,
            maxCompletionTokens: maxCompletionTokens,  // nil = use tier default (4096)
            contextWindowTokens: contextWindowTokens
        )
    }

    /// Create a manually entered model
    static func manualModel(id: String, displayName: String) -> AIProviderModel {
        AIProviderModel(
            id: id,
            displayName: displayName,
            description: "Manually configured",
            tier: .standard,
            supportsTools: true,
            supportsTemperature: true,
            supportsThinking: false,
            source: .manual,
            maxCompletionTokens: nil,  // Use tier default
            contextWindowTokens: nil
        )
    }

    /// Find a model by ID across all sources
    static func model(id: String, from allModels: [AIProviderModel]) -> AIProviderModel? {
        allModels.first { $0.id == id }
    }
}

// MARK: - OpenRouter Models

extension AIProviderModel {
    /// Default OpenRouter model ID
    static let defaultOpenRouterModelID = "anthropic/claude-3.5-sonnet"

    /// Create a model from OpenRouter API response
    static func openRouterModel(from apiModel: OpenRouterAPIModel) -> AIProviderModel {
        AIProviderModel(
            id: apiModel.id,
            displayName: apiModel.name ?? formatOpenRouterModelName(apiModel.id),
            description: formatOpenRouterDescription(apiModel),
            tier: inferOpenRouterTier(contextLength: apiModel.context_length),
            supportsTools: true,  // OpenRouter normalizes tool support
            supportsTemperature: true,
            supportsThinking: false,
            source: .openRouter,
            maxCompletionTokens: apiModel.per_request_limits?.completion_tokens,
            contextWindowTokens: apiModel.context_length
        )
    }

    /// Tier inference from context length
    private static func inferOpenRouterTier(contextLength: Int?) -> ModelTier {
        guard let ctx = contextLength else { return .standard }
        if ctx >= 128_000 { return .premium }
        if ctx >= 32_000 { return .standard }
        return .budget
    }

    /// Format model ID to display name: "anthropic/claude-3.5-sonnet" → "Claude 3.5 Sonnet"
    private static func formatOpenRouterModelName(_ id: String) -> String {
        // Remove provider prefix
        let modelPart: String
        if let slashIndex = id.firstIndex(of: "/") {
            modelPart = String(id[id.index(after: slashIndex)...])
        } else {
            modelPart = id
        }

        // Remove variant suffixes like :free, :extended, etc.
        let baseName: String
        if let colonIndex = modelPart.firstIndex(of: ":") {
            baseName = String(modelPart[..<colonIndex])
        } else {
            baseName = modelPart
        }

        // Replace hyphens with spaces and capitalize
        let formatted = baseName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        // Capitalize each word (except version numbers)
        return formatted.split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                // Keep version numbers and common abbreviations as-is
                if lower.first?.isNumber == true {
                    return String(word)
                }
                return word.capitalized
            }
            .joined(separator: " ")
    }

    /// Format description from OpenRouter model info
    private static func formatOpenRouterDescription(_ model: OpenRouterAPIModel) -> String {
        var parts: [String] = []

        // Add context length
        if let ctx = model.context_length {
            let ctxK = ctx / 1000
            parts.append("\(ctxK)K context")
        }

        // Add free indicator
        if model.isFree {
            parts.append("Free")
        }

        // Use API description or generate from context
        if let desc = model.description, !desc.isEmpty {
            // Truncate long descriptions
            let truncated = desc.prefix(60)
            if truncated.count < desc.count {
                return String(truncated) + "..."
            }
            return desc
        }

        return parts.isEmpty ? "OpenRouter model" : parts.joined(separator: " · ")
    }

    /// Get the provider slug from an OpenRouter model ID
    static func openRouterProviderSlug(for modelId: String) -> String? {
        guard let slashIndex = modelId.firstIndex(of: "/") else { return nil }
        return String(modelId[..<slashIndex])
    }
}
#endif
