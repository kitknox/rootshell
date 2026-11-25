//
//  OpenPubkeySignInView.swift
//  rootshell
//
//  "Sign In with OpenPubkey" sheet: pick an OIDC provider (or enter a
//  custom issuer), sign in via the browser, and get back an SSH key with a
//  self-signed PK-token certificate attached, ready for opkssh-enabled
//  servers.
//

import SwiftUI
import os.log

struct OpenPubkeySignInView: View {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "OpenPubkeySignIn")
    @Environment(\.dismiss) var dismiss
    var embedInNavigationStack = true

    @State private var selectedProviderID: String = OIDCProviderConfig.google.providerID
    @State private var keyName = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isAuthenticating = false
    @State private var signInTask: Task<Void, Never>?

    // Custom provider fields
    @State private var customIssuer = ""
    @State private var customClientID = ""
    @State private var customClientSecret = ""
    @State private var customScopes = "openid email profile"

    /// Distinct custom OIDC providers reused from existing opkssh keys,
    /// snapshotted on appear. Each appears as its own Provider-picker row and
    /// pre-fills the (editable) custom form when selected.
    @State private var savedCustomProviders: [OIDCProviderConfig] = []

    // Options
    @State private var showOptions = false
    @State private var storageLevel: KeyStorageLevel = .backupOnly
    @State private var sendAccessToken = false
    @State private var keyAlgorithm: OpenPubkeyKeyAlgorithm = .ed25519

    private var isCustom: Bool { selectedProviderID == "custom" }

    private var selectedBuiltIn: OIDCProviderConfig? {
        OIDCProviderConfig.builtIn.first { $0.providerID == selectedProviderID }
    }

    /// Host shown as a saved provider's row label and its default key name.
    private static func host(of provider: OIDCProviderConfig) -> String {
        URL(string: provider.issuer)?.host ?? provider.issuer
    }

    /// True when the custom form currently holds exactly this saved provider,
    /// so its row shows a checkmark. Any edit to a field clears the match.
    private func isLoaded(_ provider: OIDCProviderConfig) -> Bool {
        isCustom
            && customIssuer == provider.issuer
            && customClientID == provider.clientID
            && customClientSecret == (provider.clientSecret ?? "")
            && customScopes == provider.scopes
    }

    /// Loads a reused custom provider into the editable custom form and
    /// switches the picker to "Custom Provider".
    private func loadSavedProvider(_ provider: OIDCProviderConfig) {
        customIssuer = provider.issuer
        customClientID = provider.clientID
        customClientSecret = provider.clientSecret ?? ""
        customScopes = provider.scopes
        selectedProviderID = "custom"
    }

    /// Opens the custom form on a built-in's issuer and scopes, so the user
    /// can sign in with their own client ID instead of opkssh's shared one.
    private func useOwnClientID(for provider: OIDCProviderConfig) {
        customIssuer = provider.issuer
        customClientID = ""
        customClientSecret = ""
        customScopes = provider.scopes
        selectedProviderID = "custom"
    }

    /// Collects the distinct custom providers carried by existing opkssh keys
    /// (local + iCloud-synced), most-recent config winning per issuer+clientID.
    private static func collectSavedCustomProviders() -> [OIDCProviderConfig] {
        let infos = SSHKeyManager.shared.savedKeys
            .compactMap { $0.openPubkeyInfo }
            .filter { $0.provider.providerID == "custom" }
            .sorted { $0.lastLoginDate > $1.lastLoginDate }

        var seen = Set<String>()
        var result: [OIDCProviderConfig] = []
        for info in infos {
            let provider = info.provider
            let dedupKey = "\(provider.issuer)\n\(provider.clientID)"
            if seen.insert(dedupKey).inserted {
                result.append(provider)
            }
        }
        return result.sorted { host(of: $0).localizedCaseInsensitiveCompare(host(of: $1)) == .orderedAscending }
    }

    private var effectiveProvider: OIDCProviderConfig? {
        if let builtIn = selectedBuiltIn {
            return builtIn
        }
        let issuer = customIssuer.trimmingCharacters(in: .whitespaces)
        let clientID = customClientID.trimmingCharacters(in: .whitespaces)
        guard issuer.hasPrefix("https://"), !clientID.isEmpty else { return nil }
        let secret = customClientSecret.trimmingCharacters(in: .whitespaces)
        if customIssuerIsGoogle && secret.isEmpty { return nil }
        return OIDCProviderConfig(
            providerID: "custom",
            displayName: URL(string: issuer)?.host ?? issuer,
            issuer: issuer,
            clientID: clientID,
            clientSecret: secret.isEmpty ? nil : secret,
            scopes: customScopes.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Google's token endpoint rejects the code exchange without a secret.
    private var customIssuerIsGoogle: Bool {
        guard let url = URLComponents(string: customIssuer.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "accounts.google.com"
            && (url.port == nil || url.port == 443)
            && (url.path.isEmpty || url.path == "/")
            && url.query == nil
    }

    /// Still the built-in personal-account tenant, which org registrations can't use.
    private var customIssuerIsConsumerMicrosoft: Bool {
        customIssuer.trimmingCharacters(in: .whitespaces) == OIDCProviderConfig.azure.issuer
    }

    private var customProviderFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The OIDC client must allow the redirect URIs http://localhost:3000/login-callback, http://localhost:10001/login-callback, and http://localhost:11110/login-callback (opkssh convention).")
            if customIssuerIsConsumerMicrosoft {
                Text("This Microsoft issuer is the personal-account tenant. For a work or school app registration, replace the tenant ID in the issuer URL with your directory (tenant) ID.")
            }
        }
    }

    private var defaultKeyName: String {
        let provider = selectedBuiltIn?.displayName ?? effectiveProvider?.displayName ?? "OIDC"
        return "opkssh \(provider)"
    }

    private var canSignIn: Bool {
        effectiveProvider != nil
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProviderID) {
                    ForEach(OIDCProviderConfig.builtIn, id: \.providerID) { provider in
                        Label {
                            // Leading space: the `.menu` picker's collapsed
                            // value is UIKit-rendered and ignores SwiftUI
                            // padding, so this is how we gap the brand logo
                            // off its label.
                            Text(verbatim: Self.iconTitleGap) + Text(verbatim: provider.displayName)
                        } icon: {
                            providerIcon(imageName: provider.logoImageName,
                                         symbolName: provider.symbolName)
                        }
                        .tag(provider.providerID)
                    }
                    Label {
                        Text(verbatim: Self.iconTitleGap) + Text("Custom Provider")
                    } icon: {
                        providerIcon(imageName: nil, symbolName: "gearshape")
                    }
                    .tag("custom")
                }
                .pickerStyle(.menu)
                .themedRow()

                if let builtIn = selectedBuiltIn {
                    Button("Use Your Own Client ID") {
                        useOwnClientID(for: builtIn)
                    }
                    .themedRow()
                }
            } header: {
                Text("Identity Provider")
            } footer: {
                Text("Sign in with your account to create a short-lived SSH certificate. The server must run the opkssh verifier. Built-in providers use opkssh's shared client IDs, which are meant for testing. For production, register your own client ID, and have the server administrator replace that provider's shared entry in /etc/opk/providers with the same issuer and your client ID, or add an entry if the issuer isn't listed.")
            }

            if !savedCustomProviders.isEmpty {
                Section {
                    ForEach(savedCustomProviders, id: \.self) { provider in
                        Button {
                            loadSavedProvider(provider)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "key.horizontal")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: Self.host(of: provider))
                                        .foregroundStyle(.primary)
                                    Text(verbatim: provider.clientID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                if isLoaded(provider) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }
                } header: {
                    Text("Saved Custom Providers")
                } footer: {
                    Text("Reuse a custom provider from an existing opkssh key. Tap to load it into the form below, then edit if needed.")
                }
            }

            if isCustom {
                Section {
                    TextField("Issuer URL (https://...)", text: $customIssuer)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .themedRow()
                    TextField("Client ID", text: $customClientID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                    Group {
                        if customIssuerIsGoogle {
                            TextField("Client Secret (required for Google)", text: $customClientSecret)
                        } else {
                            TextField("Client Secret (optional)", text: $customClientSecret)
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .themedRow()
                    TextField("Scopes", text: $customScopes)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                } header: {
                    Text("Custom Provider")
                } footer: {
                    customProviderFooter
                }
            }

            ManagedKeyOptionsSections(
                defaultKeyName: defaultKeyName,
                keyName: $keyName,
                keyAlgorithm: $keyAlgorithm,
                keyTypeFooter: Text("Ed25519 is recommended. The server's opkssh verifier must accept the chosen key type."),
                storageLevel: $storageLevel,
                showOptions: $showOptions
            ) {
                Toggle("Send Access Token", isOn: $sendAccessToken)
                    .padding(.top, 4)
                Text("Include the OAuth access token in the certificate so the server can query the provider's userinfo endpoint. Leave off unless your server requires it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ManagedSignInButtonSection(
                isAuthenticating: isAuthenticating,
                canSignIn: canSignIn,
                footer: Text("Certificates last about 24 hours. The app renews them automatically when the provider issues a refresh token; otherwise you sign in again from the key's detail page."),
                action: signIn
            )
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear {
            savedCustomProviders = Self.collectSavedCustomProviders()
        }
        .navigationTitle("OpenPubkey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if embedInNavigationStack {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        signInTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .alert("Sign-In Failed", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    /// Leading whitespace inserted between a provider's logo and its name in
    /// the menu picker (UIKit ignores SwiftUI spacing on the collapsed value).
    private static let iconTitleGap = "  "

    /// Provider row icon: full-color brand logo when one exists, otherwise
    /// the SF Symbol fallback. The logo assets carry a ~20pt intrinsic size
    /// so the `.menu` picker's collapsed value renders them at icon size
    /// (UIKit ignores SwiftUI frames there and uses the asset's natural size).
    @ViewBuilder
    private func providerIcon(imageName: String?, symbolName: String) -> some View {
        if let imageName {
            Image(imageName)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: symbolName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 19, height: 19)
        }
    }

    private func signIn() {
        guard let provider = effectiveProvider else { return }
        let name = keyName.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultKeyName
            : keyName.trimmingCharacters(in: .whitespaces)
        let level = storageLevel
        let includeAccessToken = sendAccessToken
        let algorithm = keyAlgorithm

        isAuthenticating = true
        signInTask = Task {
            defer { isAuthenticating = false }
            do {
                let key = try await OpenPubkeyManager.shared.createIdentity(
                    provider: provider,
                    name: name,
                    keyAlgorithm: algorithm,
                    sendAccessToken: includeAccessToken,
                    storageLevel: level
                )
                let identity = key.openPubkeyInfo?.identityDisplay ?? name
                Self.logger.info("OpenPubkey sign-in complete for \(identity)")
                dismiss()
            } catch OIDCLoginClient.ClientError.cancelled {
                // User closed the browser sheet; stay on the form.
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}

#Preview {
    OpenPubkeySignInView()
}
