// WeatherProviderSettingsSection.swift
// rootshell

#if !CHINA_BUILD
import SwiftUI

/// Which service Live Weather uses, with a key and User-Agent for those that take them.
struct WeatherProviderSettingsSection: View {
    @ObservedObject var effect: LiveWeatherEffect
    @State private var keyDraft = ""
    @State private var showKey = false
    @State private var hasKey = false
    @State private var keyError: String?
    @State private var userAgentDraft = ""
    /// Drafts belong to this provider; reappearing rows keep them.
    @State private var loadedProvider: WeatherProviderID?
    private var store: WeatherStore { .shared }

    private var provider: WeatherProviderID { effect.configuration.provider }

    var body: some View {
        Section {
            Picker("Provider", selection: Binding(get: { provider }, set: select)) {
                ForEach(WeatherProviderID.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .themedRow()
            // On a row, not the Section, which a List applies per row.
            .onAppear {
                if loadedProvider != provider { load() }
                hasKey = provider.requiresAPIKey && WeatherCredentials.apiKey(for: provider) != nil
            }
            .onChange(of: provider) { _, _ in
                // A change from elsewhere (sync) keeps the draft too.
                commitUserAgent()
                load()
            }
            if provider.requiresAPIKey {
                keyRows
            }
            if provider.allowsCustomUserAgent {
                userAgentRow
            }
            if let url = provider.keyURL {
                Link(destination: url) {
                    Label("Get an API Key", systemImage: "arrow.up.right.square")
                }
                .themedRow()
            }
        } header: {
            Text("Weather Provider")
        } footer: {
            Text(footer)
        }
    }

    // MARK: Key

    @ViewBuilder
    private var keyRows: some View {
        HStack {
            Group {
                if showKey {
                    TextField("API Key", text: $keyDraft, prompt: Text(keyPrompt))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("API Key", text: $keyDraft, prompt: Text(keyPrompt))
                }
            }
            .textContentType(.password)
            .onSubmit(saveKey)
            Button {
                showKey.toggle()
            } label: {
                Image(systemName: showKey ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showKey ? Text("Hide API Key") : Text("Show API Key"))
        }
        .themedRow()
        if !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Save API Key", action: saveKey).themedRow()
        } else if hasKey {
            Button("Remove API Key", role: .destructive) { setKey(nil) }.themedRow()
        }
        if let keyError {
            Text(keyError).font(.caption).foregroundStyle(.red).themedRow()
        }
    }

    private var keyPrompt: String {
        hasKey
            ? String(localized: "Saved in iCloud Keychain", comment: "Weather API key field placeholder when a key is stored")
            : String(localized: "Paste your key", comment: "Weather API key field placeholder")
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        setKey(key)
    }

    private func setKey(_ key: String?) {
        do {
            try WeatherCredentials.setAPIKey(key, for: provider)
            keyError = nil
            keyDraft = ""
            showKey = false
        } catch {
            keyError = String(localized: "The key couldn't be saved to the keychain.", comment: "Weather API key error")
        }
        hasKey = WeatherCredentials.apiKey(for: provider) != nil
        store.credentialsChanged(for: provider)
    }

    // MARK: User-Agent

    private var userAgentRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("User Agent").font(.caption).foregroundStyle(.secondary)
            TextField("User Agent", text: $userAgentDraft, prompt: Text("Empty", comment: "Placeholder for a blank User-Agent"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .onSubmit(commitUserAgent)
        }
        .themedRow()
        .onDisappear(perform: commitUserAgent)
    }

    /// Commits the outgoing provider's draft in the same change as the switch.
    private func select(_ next: WeatherProviderID) {
        var configuration = effect.configuration
        storeDraft(into: &configuration)
        configuration.provider = next
        effect.configuration = configuration
    }

    private func commitUserAgent() {
        var configuration = effect.configuration
        storeDraft(into: &configuration)
        effect.configuration = configuration
        if let owner = loadedProvider { userAgentDraft = effect.configuration.userAgents[owner] ?? "" }
    }

    /// The draft belongs to the provider it was loaded for, which may no longer be selected.
    private func storeDraft(into configuration: inout LiveWeatherConfiguration) {
        guard let owner = loadedProvider, owner.allowsCustomUserAgent else { return }
        configuration.userAgents[owner] = WeatherHTTP.sanitizedUserAgent(userAgentDraft)
    }

    // MARK: Status

    private func load() {
        loadedProvider = provider
        hasKey = provider.requiresAPIKey && WeatherCredentials.apiKey(for: provider) != nil
        keyDraft = ""
        showKey = false
        keyError = nil
        userAgentDraft = effect.configuration.userAgents[provider] ?? ""
    }

    private var footer: String {
        var lines = [provider.summary]
        if provider.allowsCustomUserAgent {
            lines.append(String(localized: "Requests carry the User Agent above, or an empty one if it's left blank.", comment: "Live Weather provider footer"))
        }
        if provider.requiresAPIKey && !hasKey {
            lines.append(WeatherProviderIssue.missingKey.message(for: provider))
        } else if let issue = store.providerIssue, provider != .default {
            lines.append(issue.message(for: provider))
        }
        return lines.joined(separator: " ")
    }
}
#endif
