import SwiftUI
import AuthenticationServices

// MARK: - Add Account View

/// View for adding a new cloud provider account
struct CloudAccountAddView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @ObservedObject private var accountManager = CloudAccountManager.shared
    @ObservedObject private var cacheManager = CloudCacheManager.shared
    @StateObject private var oauthManager = OAuthFlowManager()
    @StateObject private var awsSSOManager = AWSSSOFlowManager()
    @StateObject private var azureFlowManager = AzureDeviceCodeFlowManager()

    // Form state
    @State private var selectedProvider: String = "linode"
    @State private var selectedAuthMethod: CloudAuthMethod = .pat
    @State private var accountLabel = ""
    @State private var patToken = ""

    // AWS Access Key state
    @State private var awsAccessKeyId = ""
    @State private var awsSecretAccessKey = ""
    @State private var awsRegion = AWSProvider.defaultRegion

    // Tailscale state
    @State private var tailscaleClientId = ""
    @State private var tailscaleClientSecret = ""

    // NetBird state
    @State private var netbirdManagementURL = ""

    // AWS SSO state
    @State private var awsSSOStartURL = ""
    @State private var awsSSOSession: AWSSSOSession?
    @State private var selectedAWSAccount: AWSSSOAccount?
    @State private var selectedAWSRole: AWSSSORole?
    @State private var showingAccountRoleSelection = false

    // Azure Device Code state
    @State private var azureTenantId = ""
    @State private var azureSession: AzureSession?
    @State private var selectedAzureSubscription: AzureSubscription?
    @State private var showingSubscriptionSelection = false
    @State private var isAzureFlowActive = false
    @State private var azureUserCode: String?
    @State private var azureVerificationURL: URL?
    @State private var azureStatusMessage: String?
    @State private var azureAuthSession: ASWebAuthenticationSession?
    @State private var azureAuthPresenter: AuthSessionPresenter?

    // UI state
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var showingError = false

    var body: some View {
        Form {
            providerSection
            authMethodSection

            switch selectedAuthMethod {
            case .pat:
                if selectedProvider == NetbirdProvider.providerID {
                    netbirdTokenSection
                } else {
                    patSection
                }
            case .oauth:
                oauthSection
            case .awsAccessKey:
                awsAccessKeySection
            case .awsSSO:
                awsSSOSection
            case .azureDeviceCode:
                azureDeviceCodeSection
            case .tailscaleClientCredentials:
                tailscaleClientCredentialsSection
            }

            if isValidating || oauthManager.isAuthenticating || awsSSOManager.isAuthenticating {
                progressSection
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .disabled(oauthManager.isAuthenticating || awsSSOManager.isAuthenticating || isAzureFlowActive)
        .navigationTitle("Add Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    oauthManager.cancel()
                    awsSSOManager.cancel()
                    azureFlowManager.cancel()
                    azureAuthSession?.cancel()
                    azureAuthSession = nil
                    azureAuthPresenter = nil
                    isAzureFlowActive = false
                    azureUserCode = nil
                    azureVerificationURL = nil
                    azureStatusMessage = nil
                    dismiss()
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Add") {
                    addAccount()
                }
                .disabled(!canAdd || isValidating)
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationError ?? String(localized: "Unknown error", comment: "Generic error fallback message"))
        }
        .sheet(isPresented: $showingAccountRoleSelection) {
            awsAccountRoleSelectionSheet
                .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showingSubscriptionSelection) {
            azureSubscriptionSelectionSheet
                .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $isAzureFlowActive) {
            azureDeviceCodeSheet
                .themedSubSheet(sheetThemeColors)
        }
        .onAppear {
            // Set initial auth method based on default provider
            if let firstMethod = currentProviderAuthMethods.first {
                selectedAuthMethod = firstMethod
            }
        }
    }

    private var progressSection: some View {
        Section {
            HStack {
                ProgressView()
                Text(awsSSOManager.statusMessage ?? oauthManager.statusMessage ?? String(localized: "Validating credentials...", comment: "Cloud account: validating status"))
                    .foregroundColor(.secondary)
            }
            .themedRow()

            // Show AWS SSO user code if available
            if let userCode = awsSSOManager.userCode {
                VStack(spacing: 12) {
                    Text("Enter this code in your browser:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(userCode)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)

                    if let url = awsSSOManager.verificationURL {
                        Link("Open Browser", destination: url)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .themedRow()
            }
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        Section {
            providerButton(id: LinodeProvider.providerID, name: LinodeProvider.displayName, icon: LinodeProvider.iconName, logoImage: LinodeProvider.logoImageName, authMethods: LinodeProvider.supportedAuthMethods, capabilities: LinodeProvider.capabilities)
                .themedRow()
            providerButton(id: DigitalOceanProvider.providerID, name: DigitalOceanProvider.displayName, icon: DigitalOceanProvider.iconName, logoImage: DigitalOceanProvider.logoImageName, authMethods: DigitalOceanProvider.supportedAuthMethods, capabilities: DigitalOceanProvider.capabilities)
                .themedRow()
            providerButton(id: AWSProvider.providerID, name: AWSProvider.displayName, icon: AWSProvider.iconName, logoImage: AWSProvider.logoImageName, authMethods: AWSProvider.supportedAuthMethods, capabilities: AWSProvider.capabilities)
                .themedRow()
            providerButton(id: AzureProvider.providerID, name: AzureProvider.displayName, icon: AzureProvider.iconName, logoImage: AzureProvider.logoImageName, authMethods: AzureProvider.supportedAuthMethods, capabilities: AzureProvider.capabilities)
                .themedRow()
            providerButton(id: TailscaleProvider.providerID, name: TailscaleProvider.displayName, icon: TailscaleProvider.iconName, logoImage: TailscaleProvider.logoImageName, authMethods: TailscaleProvider.supportedAuthMethods, capabilities: TailscaleProvider.capabilities)
                .themedRow()
            providerButton(id: NetbirdProvider.providerID, name: NetbirdProvider.displayName, icon: NetbirdProvider.iconName, logoImage: NetbirdProvider.logoImageName, authMethods: NetbirdProvider.supportedAuthMethods, capabilities: NetbirdProvider.capabilities)
                .themedRow()
        } header: {
            Text("Provider")
        }
    }

    private func providerButton(id: String, name: String, icon: String, logoImage: String?, authMethods: [CloudAuthMethod], capabilities: Set<CloudProviderCapability>) -> some View {
        Button {
            selectedProvider = id
            // Reset auth method when changing provider
            if let firstMethod = authMethods.first {
                selectedAuthMethod = firstMethod
            }
        } label: {
            HStack {
                providerIcon(icon: icon, logoImage: logoImage)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .foregroundColor(.primary)

                    // Only show capability chips for the selected provider
                    if selectedProvider == id {
                        capabilityChips(capabilities)
                    }
                }

                Spacer()

                if selectedProvider == id {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func providerIcon(icon: String, logoImage: String?) -> some View {
        if let logoImage = logoImage {
            Image(logoImage)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
        }
    }

    private func capabilityChips(_ capabilities: Set<CloudProviderCapability>) -> some View {
        HStack(spacing: 4) {
            ForEach(capabilities.sorted { $0.displayName < $1.displayName }, id: \.self) { capability in
                Text(capability.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundColor(.secondary)
                    .cornerRadius(4)
            }
        }
    }

    private var currentProvider: (any CloudProvider.Type)? {
        CloudProviderRegistry.shared.provider(for: selectedProvider)
    }

    // MARK: - Auth Method Section

    private var authMethodSection: some View {
        Section {
            ForEach(currentProviderAuthMethods, id: \.self) { method in
                Button {
                    selectedAuthMethod = method
                } label: {
                    HStack {
                        Image(systemName: method.iconName)
                            .foregroundColor(.accentColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.displayName)
                                .foregroundColor(.primary)
                            Text(method.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if selectedAuthMethod == method {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            }
        } header: {
            Text("Authentication")
        }
    }

    private var currentProviderAuthMethods: [CloudAuthMethod] {
        currentProvider?.supportedAuthMethods ?? [.pat, .oauth]
    }

    // MARK: - PAT Section

    private var patSection: some View {
        Section {
            TextField("e.g., Personal, Work, Production", text: $accountLabel)
                .textContentType(.name)
                .autocorrectionDisabled()
                .themedRow()

            SecureField("Personal Access Token", text: $patToken)
                .textContentType(.password)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .themedRow()
        } header: {
            Text("Account Details")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name is your personal label for this account—it can be anything you like.")
                    .padding(.bottom, 4)

                Text(patHelpText)

                Link("Generate Token", destination: patGenerateURL)
            }
        }
    }

    private var patHelpText: String {
        switch selectedProvider {
        case DigitalOceanProvider.providerID:
            return DigitalOceanProvider.patHelpText
        default:
            return LinodeProvider.patHelpText
        }
    }

    private var patGenerateURL: URL {
        switch selectedProvider {
        case DigitalOceanProvider.providerID:
            return DigitalOceanProvider.patGenerateURL
        default:
            return LinodeProvider.patGenerateURL
        }
    }

    // MARK: - OAuth Section

    private var oauthSection: some View {
        Section {
            TextField("e.g., Personal, Work, Production", text: $accountLabel)
                .textContentType(.name)
                .autocorrectionDisabled()
                .themedRow()

            Button {
                startOAuthFlow()
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text(oauthButtonText)
                }
            }
            .disabled(accountLabel.isEmpty)
            .themedRow()
        } header: {
            Text("Account Details")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name is your personal label for this account—it can be anything you like.")
                    .padding(.bottom, 4)

                Text(oauthHelpText)
            }
        }
    }

    private var oauthButtonText: String {
        switch selectedProvider {
        case DigitalOceanProvider.providerID:
            return "Sign in with DigitalOcean"
        default:
            return "Sign in with Linode"
        }
    }

    private var oauthHelpText: String {
        switch selectedProvider {
        case DigitalOceanProvider.providerID:
            return DigitalOceanProvider.oauthHelpText
        default:
            return LinodeProvider.oauthHelpText
        }
    }

    // MARK: - AWS Access Key Section

    private var awsAccessKeySection: some View {
        Section {
            TextField("e.g., Personal, Work, Production", text: $accountLabel)
                .textContentType(.name)
                .autocorrectionDisabled()
                .themedRow()

            TextField("Access Key ID", text: $awsAccessKeyId)
                .textContentType(.username)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .themedRow()

            SecureField("Secret Access Key", text: $awsSecretAccessKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .themedRow()

            Picker("Region", selection: $awsRegion) {
                ForEach(AWSProvider.regions) { region in
                    Text(region.displayName)
                        .tag(region.id)
                }
            }
            .themedRow()
        } header: {
            Text("AWS Credentials")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name is your personal label for this account—it can be anything you like.")
                    .padding(.bottom, 4)

                Text(AWSProvider.accessKeyHelpText)
                Link("AWS IAM Console", destination: AWSProvider.accessKeyGenerateURL)
            }
        }
    }

    // MARK: - AWS SSO Section

    private var awsSSOSection: some View {
        Section {
            TextField("e.g., Personal, Work, Production", text: $accountLabel)
                .textContentType(.name)
                .autocorrectionDisabled()
                .themedRow()

            TextField("SSO Start URL", text: $awsSSOStartURL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .keyboardType(.URL)
                .themedRow()

            Picker("Region", selection: $awsRegion) {
                ForEach(AWSProvider.regions) { region in
                    Text(region.displayName)
                        .tag(region.id)
                }
            }
            .themedRow()
            Button {
                startAWSSSOFlow()
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Sign in with AWS SSO")
                }
            }
            .disabled(accountLabel.isEmpty || awsSSOStartURL.isEmpty)
            .themedRow()
        } header: {
            Text("AWS SSO")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name is your personal label for this account—it can be anything you like.")
                    .padding(.bottom, 4)

                Text(AWSProvider.ssoHelpText)
            }
        }
    }

    // MARK: - Azure Device Code Section

    private var azureDeviceCodeSection: some View {
        Section {
            TextField("e.g., Personal, Work, Production", text: $accountLabel)
                .textContentType(.name)
                .autocorrectionDisabled()
                .themedRow()

            TextField("Tenant ID (optional)", text: $azureTenantId)
                .textContentType(.none)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .themedRow()

            Button {
                startAzureDeviceCodeFlow()
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Sign in with Microsoft")
                }
            }
            .disabled(accountLabel.isEmpty)
            .themedRow()
        } header: {
            Text("Microsoft Azure")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name is your personal label for this account—it can be anything you like.")
                    .padding(.bottom, 4)

                Text(AzureProvider.deviceCodeHelpText)

                Text("Leave Tenant ID empty for most accounts. Only specify if you need to target a specific Azure AD tenant.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Tailscale Client Credentials Section

    private var tailscaleClientCredentialsSection: some View {
        Section {
            TextField("e.g., Personal, Work, Home Network", text: $accountLabel)
                .textContentType(.name)
                .autocorrectionDisabled()
                .themedRow()

            TextField("OAuth Client ID", text: $tailscaleClientId)
                .textContentType(.username)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .themedRow()

            SecureField("OAuth Client Secret", text: $tailscaleClientSecret)
                .textContentType(.password)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .themedRow()
        } header: {
            Text("Tailscale Credentials")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name is your personal label for this account—it can be anything you like.")
                    .padding(.bottom, 4)

                Text(TailscaleProvider.authHelpText)

                Link("Create OAuth Client", destination: TailscaleProvider.credentialsURL)
            }
        }
    }

    // MARK: - NetBird Token Section

    private var netbirdTokenSection: some View {
        Section {
            TextField("e.g., Personal, Work, Home Network", text: $accountLabel)
                .textContentType(.name)
                .autocorrectionDisabled()
                .themedRow()

            SecureField("Personal Access Token", text: $patToken)
                .textContentType(.password)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .themedRow()

            TextField("Management URL (self-hosted, optional)", text: $netbirdManagementURL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .keyboardType(.URL)
                .themedRow()
        } header: {
            Text("NetBird Credentials")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name is your personal label for this account—it can be anything you like.")
                    .padding(.bottom, 4)

                Text(NetbirdProvider.authHelpText)

                // verbatim: avoid SwiftUI auto-linkifying the example URL
                Text(verbatim: "Leave Management URL empty for NetBird Cloud. For self-hosted, enter your management server URL (e.g. https://netbird.example.com).")
                    .font(.caption)

                Link("Open NetBird Dashboard", destination: NetbirdProvider.credentialsURL)
            }
        }
    }

    // MARK: - AWS Account/Role Selection Sheet

    private var awsAccountRoleSelectionSheet: some View {
        NavigationView {
            List {
                if !awsSSOManager.availableAccounts.isEmpty {
                    Section("AWS Account") {
                        ForEach(awsSSOManager.availableAccounts) { account in
                            Button {
                                selectedAWSAccount = account
                                Task {
                                    if let session = awsSSOSession {
                                        _ = try? await awsSSOManager.listRoles(session: session, accountId: account.accountId)
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(account.accountName)
                                        Text(account.accountId)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedAWSAccount?.id == account.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .themedRow()
                        }
                    }
                }

                if !awsSSOManager.availableRoles.isEmpty && selectedAWSAccount != nil {
                    Section("Role") {
                        ForEach(awsSSOManager.availableRoles) { role in
                            Button {
                                selectedAWSRole = role
                            } label: {
                                HStack {
                                    Text(role.roleName)
                                    Spacer()
                                    if selectedAWSRole?.id == role.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .themedRow()
                        }
                    }
                }

                if awsSSOManager.statusMessage != nil {
                    Section {
                        HStack {
                            ProgressView()
                            Text(awsSSOManager.statusMessage ?? "")
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle("Select Account & Role")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingAccountRoleSelection = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Continue") {
                        completeAWSSSOFlow()
                    }
                    .disabled(selectedAWSAccount == nil || selectedAWSRole == nil)
                }
            }
        }
    }

    // MARK: - Azure Subscription Selection Sheet

    private var azureSubscriptionSelectionSheet: some View {
        NavigationView {
            List {
                if !azureFlowManager.availableSubscriptions.isEmpty {
                    Section("Azure Subscription") {
                        ForEach(azureFlowManager.availableSubscriptions) { subscription in
                            Button {
                                selectedAzureSubscription = subscription
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(subscription.displayName)
                                        Text(subscription.subscriptionId)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedAzureSubscription?.id == subscription.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .themedRow()
                        }
                    }
                } else if azureFlowManager.statusMessage == nil {
                    // Empty state - no subscriptions available
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)

                            Text("No Subscriptions Found")
                                .font(.headline)

                            Text("If you're using a personal Microsoft account, you may need to specify your Tenant ID.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("To find your Tenant ID:")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("1. Go to Azure Portal")
                                    .font(.caption)
                                Text("2. Search for 'Microsoft Entra ID'")
                                    .font(.caption)
                                Text("3. Copy the Tenant ID from Overview")
                                    .font(.caption)
                                Text("4. Cancel and re-add with that Tenant ID")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)

                            Link(destination: URL(string: "https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview")!) {
                                Label("Open Entra ID in Portal", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .themedRow()
                    }
                }

                if azureFlowManager.statusMessage != nil {
                    Section {
                        HStack {
                            ProgressView()
                            Text(azureFlowManager.statusMessage ?? "")
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle("Select Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingSubscriptionSelection = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Continue") {
                        completeAzureDeviceCodeFlow()
                    }
                    .disabled(selectedAzureSubscription == nil)
                }
            }
        }
    }

    // MARK: - Azure Device Code Sheet

    private var azureDeviceCodeSheet: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.shield")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)

                Text("Sign in with Microsoft")
                    .font(.title2)
                    .fontWeight(.semibold)

                if let code = azureUserCode {
                    VStack(spacing: 16) {
                        Text("Enter this code at microsoft.com/devicelogin:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Text(code)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)

                        HStack(spacing: 16) {
                            Button {
                                UIPasteboard.general.string = code
                            } label: {
                                Label("Copy Code", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                continueAzureFlow()
                            } label: {
                                Label("Open Browser", systemImage: "safari")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(azureStatusMessage ?? String(localized: "Connecting to Microsoft...", comment: "Azure cloud: connection status"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text("After signing in, return to this app to continue.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Microsoft Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        azureFlowManager.cancel()
                        isAzureFlowActive = false
                        azureUserCode = nil
                        azureVerificationURL = nil
                        azureStatusMessage = nil
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Validation

    private var canAdd: Bool {
        guard !accountLabel.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }

        switch selectedAuthMethod {
        case .pat:
            return !patToken.trimmingCharacters(in: .whitespaces).isEmpty
        case .oauth:
            return false // OAuth requires the flow to complete
        case .awsAccessKey:
            return !awsAccessKeyId.trimmingCharacters(in: .whitespaces).isEmpty &&
                   !awsSecretAccessKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .awsSSO:
            return false // SSO requires the flow to complete
        case .azureDeviceCode:
            return false // Azure device code requires the flow to complete
        case .tailscaleClientCredentials:
            return !tailscaleClientId.trimmingCharacters(in: .whitespaces).isEmpty &&
                   !tailscaleClientSecret.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Actions

    private func addAccount() {
        guard canAdd else { return }

        isValidating = true
        validationError = nil

        Task {
            do {
                let accountID = UUID()
                let credentials: CloudCredentials
                let awsRegionForAccount: String?

                switch selectedAuthMethod {
                case .pat:
                    if selectedProvider == NetbirdProvider.providerID {
                        let mgmtURL = netbirdManagementURL.trimmingCharacters(in: .whitespaces)
                        credentials = CloudCredentials.netbird(
                            accountID: accountID,
                            token: patToken.trimmingCharacters(in: .whitespaces),
                            managementURL: mgmtURL.isEmpty ? nil : mgmtURL
                        )
                    } else {
                        credentials = CloudCredentials.pat(
                            accountID: accountID,
                            providerID: selectedProvider,
                            token: patToken.trimmingCharacters(in: .whitespaces)
                        )
                    }
                    awsRegionForAccount = nil

                case .awsAccessKey:
                    credentials = CloudCredentials.awsAccessKey(
                        accountID: accountID,
                        region: awsRegion,
                        accessKeyId: awsAccessKeyId.trimmingCharacters(in: .whitespaces),
                        secretAccessKey: awsSecretAccessKey.trimmingCharacters(in: .whitespaces)
                    )
                    awsRegionForAccount = awsRegion

                case .tailscaleClientCredentials:
                    credentials = CloudCredentials.tailscale(
                        accountID: accountID,
                        clientId: tailscaleClientId.trimmingCharacters(in: .whitespaces),
                        clientSecret: tailscaleClientSecret.trimmingCharacters(in: .whitespaces)
                    )
                    awsRegionForAccount = nil

                default:
                    // OAuth and SSO are handled by their respective flows
                    isValidating = false
                    return
                }

                // Validate credentials using provider-specific client
                let client = createAPIClient(credentials: credentials, accountID: accountID)
                let isValid = try await client.validateCredentials()

                guard isValid else {
                    await MainActor.run {
                        switch selectedAuthMethod {
                        case .awsAccessKey:
                            validationError = "Invalid credentials. Please check your Access Key ID and Secret."
                        case .tailscaleClientCredentials:
                            validationError = "Invalid credentials. Please check your Client ID and Secret."
                        default:
                            validationError = "Invalid token. Please check your Personal Access Token."
                        }
                        showingError = true
                        isValidating = false
                    }
                    return
                }

                // For Tailscale, get the updated credentials with access token
                var credentialsToSave = credentials
                if let tailscaleClient = client as? TailscaleAPIClient {
                    credentialsToSave = tailscaleClient.currentCredentials
                }

                // Add account
                try accountManager.addAccount(
                    providerID: selectedProvider,
                    label: accountLabel.trimmingCharacters(in: .whitespaces),
                    authMethod: selectedAuthMethod,
                    credentials: credentialsToSave,
                    awsRegion: awsRegionForAccount
                )

                // Initial sync
                await cacheManager.syncAccount(accountID)

                await MainActor.run {
                    isValidating = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    validationError = error.localizedDescription
                    showingError = true
                    isValidating = false
                }
            }
        }
    }

    private func startOAuthFlow() {
        let label = accountLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }

        Task {
            do {
                // Start OAuth flow for the selected provider
                var credentials: CloudCredentials
                switch selectedProvider {
                case DigitalOceanProvider.providerID:
                    credentials = try await oauthManager.startDigitalOceanOAuth(accountLabel: label)
                default:
                    credentials = try await oauthManager.startLinodeOAuth(accountLabel: label)
                }

                // Generate a new account ID for storage
                let accountID = UUID()

                // Recreate credentials with the account ID we'll use for storage
                credentials = CloudCredentials.oauth(
                    accountID: accountID,
                    providerID: selectedProvider,
                    accessToken: credentials.oauthAccessToken!,
                    refreshToken: credentials.oauthRefreshToken,
                    expiresAt: credentials.oauthExpiresAt,
                    scopes: credentials.oauthScopes
                )

                // Validate the token works using provider-specific client
                let client = createAPIClient(credentials: credentials, accountID: accountID)
                let isValid = try await client.validateCredentials()

                guard isValid else {
                    validationError = "OAuth authentication succeeded but token validation failed."
                    showingError = true
                    return
                }

                // Add account
                try accountManager.addAccount(
                    providerID: selectedProvider,
                    label: label,
                    authMethod: .oauth,
                    credentials: credentials
                )

                // Initial sync
                await cacheManager.syncAccount(accountID)

                dismiss()
            } catch is CancellationError {
                // User cancelled, do nothing
            } catch {
                validationError = error.localizedDescription
                showingError = true
            }
        }
    }

    private func startAWSSSOFlow() {
        let label = accountLabel.trimmingCharacters(in: .whitespaces)
        let startURL = awsSSOStartURL.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty && !startURL.isEmpty else { return }

        Task {
            do {
                // Start SSO flow
                let session = try await awsSSOManager.startSSOFlow(startURL: startURL, region: awsRegion)
                awsSSOSession = session

                // Load available accounts
                _ = try await awsSSOManager.listAccounts(session: session)

                // Show account/role selection
                showingAccountRoleSelection = true
            } catch is CancellationError {
                // User cancelled
            } catch {
                validationError = error.localizedDescription
                showingError = true
            }
        }
    }

    private func completeAWSSSOFlow() {
        guard let session = awsSSOSession,
              let account = selectedAWSAccount,
              let role = selectedAWSRole else {
            return
        }

        showingAccountRoleSelection = false

        Task {
            do {
                // Get STS credentials for the selected role
                let stsCredentials = try await awsSSOManager.getCredentials(
                    session: session,
                    accountId: account.accountId,
                    roleName: role.roleName
                )

                let accountID = UUID()
                let credentials = CloudCredentials.awsSSO(
                    accountID: accountID,
                    region: awsRegion,
                    ssoSession: session,
                    awsAccountId: account.accountId,
                    roleName: role.roleName,
                    stsCredentials: stsCredentials
                )

                // Validate credentials
                let client = createAPIClient(credentials: credentials, accountID: accountID)
                let isValid = try await client.validateCredentials()

                guard isValid else {
                    validationError = "SSO authentication succeeded but credential validation failed."
                    showingError = true
                    return
                }

                // Add account
                try accountManager.addAccount(
                    providerID: AWSProvider.providerID,
                    label: accountLabel.trimmingCharacters(in: .whitespaces),
                    authMethod: .awsSSO,
                    credentials: credentials,
                    awsRegion: awsRegion
                )

                // Initial sync
                await cacheManager.syncAccount(accountID)

                dismiss()
            } catch {
                validationError = error.localizedDescription
                showingError = true
            }
        }
    }

    private func startAzureDeviceCodeFlow() {
        let label = accountLabel.trimmingCharacters(in: .whitespaces)
        let tenantId = azureTenantId.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }

        // Set local state immediately - this shows the sheet
        isAzureFlowActive = true
        azureUserCode = nil
        azureVerificationURL = nil
        azureStatusMessage = "Connecting to Microsoft..."

        Task {
            do {
                // Phase 1: Just get the device code (no polling yet)
                try await azureFlowManager.requestCode(
                    tenantId: tenantId.isEmpty ? "organizations" : tenantId
                )

                // Update local state with code
                azureUserCode = azureFlowManager.userCode
                azureVerificationURL = azureFlowManager.verificationURL
                azureStatusMessage = azureFlowManager.statusMessage

                // Copy to clipboard
                if let code = azureUserCode {
                    UIPasteboard.general.string = code
                }

                // Now we wait - user will tap "Open Browser" which calls continueAzureFlow()

            } catch is CancellationError {
                clearAzureFlowState()
            } catch AzureError.cancelled {
                clearAzureFlowState()
            } catch {
                clearAzureFlowState()
                validationError = error.localizedDescription
                showingError = true
            }
        }
    }

    /// Called when user taps "Open Browser" - opens in-app browser and starts polling
    private func continueAzureFlow() {
        guard let url = azureVerificationURL else { return }

        azureStatusMessage = "Waiting for authorization..."

        // Create in-app browser session (no callback expected for device code flow)
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { _, error in
            // User dismissed browser - cancel flow if still pending
            if error != nil {
                Task { @MainActor in
                    self.azureFlowManager.cancel()
                }
            }
        }

        // Keep presenter alive while session is active
        let presenter = AuthSessionPresenter()
        azureAuthPresenter = presenter
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        azureAuthSession = session
        session.start()

        // Start polling concurrently
        Task {
            do {
                // Phase 2: Start polling for authorization
                let polledSession = try await azureFlowManager.startPolling()
                azureSession = polledSession

                // Success - dismiss browser
                azureAuthSession?.cancel()
                azureAuthSession = nil
                azureAuthPresenter = nil

                // Clear flow state
                clearAzureFlowState()

                // Load available subscriptions
                _ = try await azureFlowManager.listSubscriptions(session: polledSession)

                // Show subscription selection
                showingSubscriptionSelection = true
            } catch is CancellationError {
                azureAuthSession?.cancel()
                azureAuthSession = nil
                azureAuthPresenter = nil
                clearAzureFlowState()
            } catch AzureError.cancelled {
                azureAuthSession?.cancel()
                azureAuthSession = nil
                azureAuthPresenter = nil
                clearAzureFlowState()
            } catch {
                azureAuthSession?.cancel()
                azureAuthSession = nil
                azureAuthPresenter = nil
                clearAzureFlowState()
                validationError = error.localizedDescription
                showingError = true
            }
        }
    }

    private func clearAzureFlowState() {
        isAzureFlowActive = false
        azureUserCode = nil
        azureVerificationURL = nil
        azureStatusMessage = nil
    }

    private func completeAzureDeviceCodeFlow() {
        guard let session = azureSession,
              let subscription = selectedAzureSubscription else {
            return
        }

        showingSubscriptionSelection = false

        Task {
            do {
                let accountID = UUID()
                let credentials = CloudCredentials.azureDeviceCode(
                    accountID: accountID,
                    tenantId: session.tenantId,
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken,
                    expiresAt: session.tokenExpiresAt,
                    subscriptionId: subscription.subscriptionId,
                    subscriptionName: subscription.displayName
                )

                // Validate credentials
                let client = createAPIClient(credentials: credentials, accountID: accountID)
                let isValid = try await client.validateCredentials()

                guard isValid else {
                    validationError = "Azure authentication succeeded but credential validation failed."
                    showingError = true
                    return
                }

                // Add account
                try accountManager.addAccount(
                    providerID: AzureProvider.providerID,
                    label: accountLabel.trimmingCharacters(in: .whitespaces),
                    authMethod: .azureDeviceCode,
                    credentials: credentials
                )

                // Initial sync
                await cacheManager.syncAccount(accountID)

                dismiss()
            } catch {
                validationError = error.localizedDescription
                showingError = true
            }
        }
    }

    private func createAPIClient(credentials: CloudCredentials, accountID: UUID) -> any CloudProviderAPIClient {
        switch selectedProvider {
        case DigitalOceanProvider.providerID:
            return DigitalOceanAPIClient(credentials: credentials, accountID: accountID)
        case AWSProvider.providerID:
            return AWSAPIClient(credentials: credentials, accountID: accountID)
        case AzureProvider.providerID:
            return AzureAPIClient(credentials: credentials, accountID: accountID)
        case TailscaleProvider.providerID:
            return TailscaleAPIClient(credentials: credentials, accountID: accountID)
        case NetbirdProvider.providerID:
            return NetbirdAPIClient(credentials: credentials, accountID: accountID)
        default:
            return LinodeAPIClient(credentials: credentials, accountID: accountID)
        }
    }
}

// MARK: - Auth Session Presenter

/// Helper class for ASWebAuthenticationSession presentation context
/// Required because SwiftUI structs cannot conform to NSObject protocols
private class AuthSessionPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let window = UIApplication.shared.deviceKeyWindow else {
            fatalError("No window available for ASWebAuthenticationSession")
        }
        return window
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        CloudAccountAddView()
    }
}
