import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// View for creating a new SSH connection
struct SSHConnectionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var sshKeyManager = SSHKeyManager.shared
    @ObservedObject private var historyManager = SSHConnectionHistoryManager.shared
    @ObservedObject private var clusterManager = KubernetesClusterManager.shared
    @ObservedObject private var suggestionProvider = QuickConnectSuggestionProvider.shared
    @ObservedObject private var cloudAccountManager = CloudAccountManager.shared
    @ObservedObject private var locationDiaryManager = LocationDiaryManager.shared

    // Quick connect field
    @State private var quickConnectText: String = ""
    @State private var isQuickConnectFocused: Bool = false
    
    // Split option for how to open the connection
    // (internal: shared with the Screen Sharing form extension)
    @State var quickConnectProfile: ConnectionProfile?
    @State var splitOption: SplitOption = .newTab
    
    // Kubernetes-specific state
    @State private var selectedCluster: KubernetesCluster?
    @State private var nodes: [ClusterNodeInfo] = []
    @State private var selectedNode: ClusterNodeInfo?
    @State private var isLoadingNodes: Bool = false
    @State private var nodeSearchQuery: String = ""
    @State private var selectedPodType: KubernetesDebugPodType = .nodeShell
    
    // Console-specific state
    @State private var selectedConsoleAccountIDs: Set<UUID> = []  // Empty = all accounts
    @State private var showAccountFilter: Bool = false
    @State private var allConsoleInstances: [CloudInstance] = []
    @State private var hasLoadedConsoleInstances: Bool = false
    @State private var consoleInstanceSearchQuery: String = ""
    
    // Target server fields
    @State private var hostname: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var savePassword: Bool = true  // Save password to Keychain
    
    @State private var authMethod: AuthType = .password
    @State private var selectedKeyID: UUID?
    @State private var isJumpHostExpanded: Bool = false
    @State private var isAgentForwardingExpanded: Bool = false
    @State private var isPortForwardingExpanded: Bool = false
    @State private var isTerminalOptionsExpanded: Bool = false
    
    // Jump host fields
    @State private var useJumpHost: Bool = false
    @State private var jumpHostname: String = ""
    @State private var jumpPort: String = "22"
    @State private var jumpUsername: String = ""
    @State private var jumpPassword: String = ""
    @State private var saveJumpPassword: Bool = true  // Save jump host password to Keychain
    @State private var jumpAuthMethod: AuthType = .key
    @State private var jumpSelectedKeyID: UUID?
    
    // Agent forwarding
    @State private var enableAgentForwarding: Bool = false
    @State private var agentApprovalMode: SSHAgentConfig.ApprovalMode = .perRequest
    @State private var agentForwardAllKeys: Bool = true
    @State private var agentSelectedKeyIDs: Set<UUID> = []

    // GPG agent forwarding
    @State private var isGPGAgentForwardingExpanded: Bool = false
    @State private var enableGPGAgentForwarding: Bool = false
    @State private var gpgAgentApprovalMode: GPGAgentConfig.ApprovalMode = .perRequest
    @State private var gpgForwardAllKeys: Bool = true
    @State private var gpgSelectedKeyIDs: Set<UUID> = []
    @State private var gpgRemoteSocketPath: String = GPGAgentConfig.defaultRemoteSocketPath

    // Port forwarding
    @State private var portForwards: [PortForwardConfig.PortForward] = []
    @State private var showPortForwardBackgroundAlert: Bool = false
    
    // tmux auto-enable
    @State private var enableTmux: Bool = false

    // tmux launch mode (regular vs control/-CC), meaningful when enableTmux is on
    @State private var tmuxAutoMode: TmuxAutoMode = .regular

    // herdr auto-attach (mutually exclusive with enableTmux via the picker)
    @State private var enableHerdr: Bool = false

    // zmx auto-attach (mutually exclusive with the others via the picker)
    @State private var enableZmx: Bool = false

    // Launch command
    @State private var launchCommand: String = ""
    @State private var launchCommandMode: SSHConfig.LaunchCommandMode = .afterConnect

    // TERM override carried in from a history entry or profile. Not editable
    // here — the profile editor owns that UI. Empty inherits the global default.
    @State private var terminalType: String = ""

    // Multiplexer session name carried in the same way. Also not editable here.
    @State private var multiplexerSessionName: String = ""

    /// Normalized identity (user@host:port) the carried overrides were restored
    /// for. They are only valid for that destination, so retargeting the form at
    /// a different connection drops them.
    @State private var carriedOverrideEndpoint: String?

    // Connection protocol (SSH or Mosh)
    @State private var connectionProtocol: ConnectionProtocol = .ssh

    // Screen Sharing (VNC) form fields (shared with the profile editor)
    @State var vncForm = VNCFormState()

    // Keeps the host/username/jump fields when switching between the SSH and
    // Screen Sharing tabs, which present separate field sets
    @State private var endpointCarryOver = ConnectionEndpointCarryOver()
    
    // Initialization tracking (prevents onAppear from resetting state on navigation return)
    @State private var hasInitialized: Bool = false
    
    // Globals the multiplexer captions fall back to. Observed rather than read
    // directly so the captions refresh when Settings change; the values
    // themselves come from SSHConfig.multiplexerSessionDisplayName.
    @Setting(Settings.Multiplexer.tmuxSessionName) private var tmuxSessionNameSetting
    @Setting(Settings.Multiplexer.tmuxCustomCommand) private var tmuxCustomCommandSetting
    @Setting(Settings.Multiplexer.herdrSessionName) private var herdrSessionNameSetting
    @Setting(Settings.Multiplexer.herdrCustomCommand) private var herdrCustomCommandSetting

    /// Session name the multiplexer captions describe: the override carried in
    /// from a profile or history entry, else the global.
    private var multiplexerCaptionSessionName: String {
        SSHConfig.multiplexerSessionDisplayName(for: tmuxLaunchSelection.wrappedValue,
                                                override: multiplexerSessionName)
    }
    
    @State private var isConnecting: Bool = false
    // (internal: shared with the Screen Sharing form extension)
    @State var errorMessage: String?
    
    // Profile editor (pushed onto NavigationStack in sidebar, sheet on iPhone)
    @State private var showProfileEditorSheet: Bool = false
    
    // HSS tracking
    @State private var currentHSSShorthand: String? = nil
    
    // Cloud instance suggestion tracking
    @State private var selectedSuggestionDetail: String? = nil
    @State private var selectedCloudInstanceLabel: String? = nil
    
    // Cached console-capable accounts (computed once on appear, invalidated on account changes)
    @State private var cachedConsoleCapableAccounts: [CloudAccount]? = nil
    
    /// Optional initial configuration for retry scenarios
    let initialConfig: SSHConfig?
    
    /// Optional initial browse selection (from MainView CMD+B)
    let initialBrowseSelection: BrowseHostSelection?
    
    /// Callback when connection is successfully initiated (nil config = local shell)
    var onConnect: (SSHConfig?, SplitOption) -> Void
    
    /// Callback when Mosh connection is initiated
    var onMoshConnect: ((MoshConfig, SplitOption) -> Void)? = nil
    
    /// Callback when Trzsz connection is initiated
    var onTrzszConnect: ((TrzszConfig, SplitOption) -> Void)? = nil

    /// Callback when a Screen Sharing (VNC) connection is initiated
    var onVNCConnect: ((VNCConnectionConfig, SplitOption) -> Void)? = nil

    /// Callback when Kubernetes node shell connection is initiated
    var onKubernetesConnect: ((KubernetesNodeShellConfig, SplitOption) -> Void)? = nil
    
    /// Callback when Console connection is initiated (Linode LISH)
    var onConsoleConnect: ((ConsoleConfig, SplitOption) -> Void)? = nil
    
    /// Callback when EC2 Console connection is initiated
    var onEC2ConsoleConnect: ((EC2ConsoleConfig, SplitOption) -> Void)? = nil
    
    /// Callback when a profile is selected for connection
    var onProfileConnect: ((ConnectionProfile, SplitOption) -> Void)? = nil
    
    /// When true, the Cancel button is hidden (no terminal to return to)
    var preventDismissal: Bool = false
    
    /// Sidebar close callback. When set, "Cancel" becomes "Done" and calls this instead of dismiss().
    var onClose: (() -> Void)? = nil
    
    /// Dismiss the view — uses onClose for sidebar, dismiss() for sheet
    func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
    
    /// Initial tab to show when the view appears (overrides persisted lastConnectionType)
    var initialTab: ConnectionSidebarTab? = nil
    
    /// Custom initializer with default values for optional callbacks
    init(
        initialConfig: SSHConfig? = nil,
        initialBrowseSelection: BrowseHostSelection? = nil,
        onConnect: @escaping (SSHConfig?, SplitOption) -> Void,
        onMoshConnect: ((MoshConfig, SplitOption) -> Void)? = nil,
        onTrzszConnect: ((TrzszConfig, SplitOption) -> Void)? = nil,
        onVNCConnect: ((VNCConnectionConfig, SplitOption) -> Void)? = nil,
        onKubernetesConnect: ((KubernetesNodeShellConfig, SplitOption) -> Void)? = nil,
        onConsoleConnect: ((ConsoleConfig, SplitOption) -> Void)? = nil,
        onEC2ConsoleConnect: ((EC2ConsoleConfig, SplitOption) -> Void)? = nil,
        onProfileConnect: ((ConnectionProfile, SplitOption) -> Void)? = nil,
        preventDismissal: Bool = false,
        onClose: (() -> Void)? = nil,
        initialTab: ConnectionSidebarTab? = nil
    ) {
        self.initialConfig = initialConfig
        self.initialBrowseSelection = initialBrowseSelection
        self.onConnect = onConnect
        self.onMoshConnect = onMoshConnect
        self.onTrzszConnect = onTrzszConnect
        self.onVNCConnect = onVNCConnect
        self.onKubernetesConnect = onKubernetesConnect
        self.onConsoleConnect = onConsoleConnect
        self.onEC2ConsoleConnect = onEC2ConsoleConnect
        self.onProfileConnect = onProfileConnect
        self.preventDismissal = preventDismissal
        self.onClose = onClose
        self.initialTab = initialTab
        
        // Pre-initialize connectionType to match what onAppear would set.
        // This prevents .id(connectionType) from triggering a view recreation
        // during the sidebar's slide-in animation.
        let lastRaw = SettingsStore.shared.get(Settings.Connections.lastConnectionType) ?? "Profiles"
        let defaultType = ConnectionType(rawValue: lastRaw) ?? .profiles
        if let initialTab {
            switch initialTab {
            case .lastUsed: _connectionType = State(initialValue: defaultType)
            case .ssh: _connectionType = State(initialValue: .ssh)
            case .vnc: _connectionType = State(initialValue: .vnc)
            case .profiles: _connectionType = State(initialValue: .profiles)
            case .browse: _connectionType = State(initialValue: .browse)
            case .local: _connectionType = State(initialValue: .local)
            case .kubernetes: _connectionType = State(initialValue: .kubernetes)
            case .console: _connectionType = State(initialValue: .console)
            }
        } else {
            _connectionType = State(initialValue: defaultType)
        }
    }
    
    enum ConnectionType: String, CaseIterable {
        case profiles = "Profiles"
        case ssh = "SSH"
        case vnc = "Screen Sharing"
        case browse = "Browse"
        case local = "Local Shell"
        case kubernetes = "Kubernetes"
        case console = "Console"

        var displayName: String {
            switch self {
            case .profiles: return String(localized: "Profiles")
            case .ssh: return String(localized: "SSH")
            case .vnc: return String(localized: "Screen Sharing")
            case .browse: return String(localized: "Browse")
            case .local: return String(localized: "Local Shell")
            case .kubernetes: return String(localized: "Kubernetes")
            case .console: return String(localized: "Console")
            }
        }

        var iconName: String {
            switch self {
            case .profiles: return "star.fill"
            case .ssh: return "terminal"
            case .vnc: return "display"
            case .browse: return "list.bullet.rectangle"
            case .local: return "macwindow"
            case .kubernetes: return "helm"
            case .console: return "server.rack"
            }
        }
    }
    
    private var availableConnectionTypes: [ConnectionType] {
        var types: [ConnectionType] = [.ssh]
        
#if targetEnvironment(macCatalyst)
        if helperAvailable {
            types.append(.local)
        }
#else
        types.append(.local)
#endif

        types.append(.vnc)

        types.append(.browse)

        types.append(.kubernetes)
        
        // Only show Console if there's at least one account with console capability
        if hasConsoleCapableAccounts {
            types.append(.console)
        }
        
        return types
    }
    
    private var visibleConnectionTypes: [ConnectionType] {
        [.profiles] + availableConnectionTypes
    }
    
    /// Whether any cloud accounts support console access
    private var hasConsoleCapableAccounts: Bool {
        !consoleCapableAccounts.isEmpty
    }
    
    /// Cloud accounts that support console access (uses cache when available)
    private var consoleCapableAccounts: [CloudAccount] {
        if let cached = cachedConsoleCapableAccounts {
            return cached
        }
        return computeConsoleCapableAccounts()
    }
    
    /// Compute console-capable accounts (called once, then cached)
    private func computeConsoleCapableAccounts() -> [CloudAccount] {
        cloudAccountManager.accounts.filter { account in
            guard let provider = CloudProviderRegistry.shared.provider(for: account.providerID) else {
                return false
            }
            return provider.capabilities.contains(.console)
        }
    }
    
    private var localShellTitle: String {
#if targetEnvironment(macCatalyst)
        return String(localized: "Create Local Shell")
#else
        return String(localized: "Create iOS Local Shell")
#endif
    }
    
    private var localShellDescription: String {
#if targetEnvironment(macCatalyst)
        return String(localized: "Launch a full login shell on this Mac via Rootshell Helper. The helper provides unsandboxed PTY access, so make sure it is running before connecting.")
#else
        return String(localized: "Run commands locally on your iOS device. Supported commands include ls, cd, pwd, cat, grep, curl, and more.")
#endif
    }
    
    private var navigationTitleForConnectionType: String {
        if let _ = initialConfig {
            return String(localized: "Retry SSH Connection")
        }
        switch connectionType {
        case .profiles: return String(localized: "Profiles")
        case .ssh: return String(localized: "SSH")
        case .vnc: return String(localized: "Screen Sharing")
        case .browse: return String(localized: "Browse")
        case .local: return String(localized: "Local Shell")
        case .kubernetes: return String(localized: "Kubernetes")
        case .console: return String(localized: "Console")
        }
    }
    
    enum SplitOption: String, CaseIterable {
        case newTab = "New Tab"
        case splitRight = "Split Right"
        case splitDown = "Split Down"
        
        var displayName: String {
            switch self {
            case .newTab: return String(localized: "New Tab")
            case .splitRight: return String(localized: "Split Right")
            case .splitDown: return String(localized: "Split Down")
            }
        }
    }
    
    enum AuthType: String, CaseIterable {
        case password = "Password"
        case key = "SSH Key"
        case keyboardInteractive = "Keyboard-Interactive"
        case none = "None"
        
        var displayName: String {
            switch self {
            case .password: return String(localized: "Password")
            case .key: return String(localized: "SSH Key")
            case .keyboardInteractive: return String(localized: "Keyboard-Interactive")
            case .none: return String(localized: "None")
            }
        }
    }
    
    enum InlineProfilesRoute: Hashable {
        case folder(String)
        
        var folderPath: String {
            switch self {
            case .folder(let path):
                return path
            }
        }
    }
    
    // Persist last selected connection type
    @Setting(Settings.Connections.lastConnectionType) private var lastConnectionTypeRaw

    private var defaultConnectionType: ConnectionType {
        ConnectionType(rawValue: lastConnectionTypeRaw ?? "Profiles") ?? .profiles
    }
    
    // Internal (not private) so the +VNC extension file can switch forms.
    @State var connectionType: ConnectionType = .ssh
    @State private var inlineProfilesPath: [InlineProfilesRoute] = []
#if targetEnvironment(macCatalyst)
    @State private var helperAvailable: Bool = false
#endif
    @Namespace private var connectionTypeTabNamespace

    var body: some View {
        NavigationStack(path: $inlineProfilesPath) {
            navigationStackContent
        }
        .overlay {
            // Single Esc handler for the entire connection view.
            // Navigates back through profile folders first, then closes.
            if !preventDismissal {
                Button("") {
                    if connectionType == .profiles && !inlineProfilesPath.isEmpty {
                        inlineProfilesPath.removeLast()
                    } else {
                        close()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        #if !targetEnvironment(macCatalyst)
        .alert(
            String(localized: "Keep Port Forwards Alive"),
            isPresented: $showPortForwardBackgroundAlert
        ) {
            Button(String(localized: "Enable Auto Location")) {
                locationDiaryManager.mode = .autoForRemote
                locationDiaryManager.requestPermission()
                SettingsStore.shared.set(Settings.Connections.hasSeenPortForwardBackgroundPrompt, true)
            }
            Button(String(localized: "Not Now"), role: .cancel) {
                SettingsStore.shared.set(Settings.Connections.hasSeenPortForwardBackgroundPrompt, true)
            }
        } message: {
            Text("iOS suspends apps in the background, which stops SSH port forwards. Enable Auto Location to keep connections alive when you switch apps.")
        }
        #endif
    }
    
    private var navigationStackContent: some View {
        connectionContent
            .background(sheetThemeColors?.background ?? Color(.systemGroupedBackground))
            .onChange(of: quickConnectText) { _, newValue in
                updateFieldsFromQuickConnect(newValue)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { connectionToolbar }
            .onChange(of: useJumpHost) { _, enabled in
                if enabled && jumpSelectedKeyID == nil {
                    jumpSelectedKeyID = selectedKeyID
                }
                if enabled {
                    isJumpHostExpanded = true
                }
            }
            .onChange(of: enableAgentForwarding) { _, enabled in
                if enabled {
                    isAgentForwardingExpanded = true
                }
            }
            .onChange(of: portForwards.count) { _, count in
                if count > 0 {
                    isPortForwardingExpanded = true
                }
            }
            .onChange(of: enableTmux) { _, enabled in
                if enabled {
                    isTerminalOptionsExpanded = true
                }
            }
            .onChange(of: enableHerdr) { _, enabled in
                if enabled {
                    isTerminalOptionsExpanded = true
                }
            }
            .onChange(of: enableZmx) { _, enabled in
                if enabled {
                    isTerminalOptionsExpanded = true
                }
            }
            .onChange(of: launchCommand) { _, newValue in
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    isTerminalOptionsExpanded = true
                }
            }
            .onChange(of: connectionType) { oldType, newType in
                if newType != .profiles {
                    inlineProfilesPath = []
                }
                if newType == .kubernetes && selectedCluster == nil && clusterManager.clusters.count == 1 {
                    selectedCluster = clusterManager.clusters.first
                }
                carryEndpointBetweenTabs(from: oldType, to: newType)
            }
            .onAppear(perform: handleConnectionViewAppear)
            .task { await handleConnectionViewTask() }
            .onChange(of: cloudAccountManager.accounts) { _, _ in
                cachedConsoleCapableAccounts = computeConsoleCapableAccounts()
            }
#if targetEnvironment(macCatalyst)
            .onChange(of: helperAvailable) { _, isAvailable in
                if !isAvailable && connectionType == .local {
                    connectionType = .ssh
                }
            }
#endif
            .navigationDestination(isPresented: $showProfileEditorSheet) {
                ProfileEditorSheet(historyEntry: buildHistoryEntryFromForm(), embedded: true)
            }
    }
    
    @ToolbarContentBuilder
    private var connectionToolbar: some ToolbarContent {
        if !preventDismissal {
            ToolbarItem(placement: .topBarLeading) {
                Button(onClose != nil ? "Done" : "Cancel") {
                    if let onClose {
                        onClose()
                    } else {
                        close()
                    }
                }
                .disabled(isConnecting)
            }
        }
        
        ToolbarItem(placement: .principal) {
            Text(navigationTitleForConnectionType)
                .fontWeight(.semibold)
        }
        
        ToolbarItem(placement: .confirmationAction) {
            if connectionType == .console || connectionType == .profiles || connectionType == .browse {
                EmptyView()
            } else if isConnecting {
                ProgressView()
            } else {
                Button(connectionType == .local ? "Open" : "Connect") {
                    connect()
                }
                .disabled(!isFormValid)
            }
        }
    }
    
    @ViewBuilder
    private var connectionContent: some View {
        VStack(spacing: 0) {
            connectionTypeSwitcher
            
            Divider()
            
            switch connectionType {
            case .ssh:
                sshConnectionContent
            case .vnc:
                vncConnectionContent
            case .profiles:
                profilesConnectionContent
            case .browse:
                browseConnectionContent
            case .local:
                localShellConnectionContent
            case .kubernetes:
                kubernetesConnectionView
            case .console:
                consoleConnectionView
            }
        }
    }
    
    private var sshConnectionContent: some View {
        VStack(spacing: 0) {
            sshQuickConnectSection
            compactOpenAsHeader
            sshFormContent
        }
    }
    
    private var sshQuickConnectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            quickConnectHeaderLine
                .padding(.top, 8)
                .padding(.horizontal, 16)
            
            QuickConnectField(
                text: $quickConnectText,
                isFocused: $isQuickConnectFocused,
                placeholder: String(localized: "user@host, !alias, or VM name", comment: "Quick connect: placeholder text"),
                suggestionProvider: suggestionProvider,
                onCommit: handleQuickConnect,
                onSuggestionAccepted: handleUnifiedSuggestionAccepted,
                containerBackgroundColor: sheetThemeColors.map { UIColor($0.rowBackground) }
            )
            .frame(height: 44)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            
            Divider()
        }
        .background(sheetThemeColors?.background ?? Color(.systemGroupedBackground))
    }
    
    private var sshFormContent: some View {
        Form {
            if let errorMessage {
                Section {
                    Group {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                    .themedRow()
                }
            }
            
            sshServerSection
            sshAuthenticationSection
            sshAdvancedSection
            
            if canSaveAsProfile {
                Section {
                    Group {
                        Button {
                            showProfileEditorSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "star")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Save as Profile...")
                                        .foregroundColor(.accentColor)
                                    Text("Reuse these settings on every device.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .themedRow()
                }
            }
        }
        .themedList()
#if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
#endif
    }
    
    private var sshServerSection: some View {
        Section("Server") {
            Group {
                // Screen Sharing has its own connection tab; the terminal
                // protocols are the only valid choices here.
                Picker("Protocol", selection: $connectionProtocol) {
                    ForEach(ConnectionProtocol.allCases.filter { $0 != .vnc && $0 != .local }, id: \.self) { proto in
                        Label(proto.displayName, systemImage: proto.iconName).tag(proto)
                    }
                }
                .pickerStyle(.menu)

                TextField("Hostname or IP", text: $hostname)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("22", text: $port)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
            }
            .themedRow()
        }
    }
    
    // Keyboard-interactive is surfaced as a toggle under the Password method
    // rather than a fourth segment (which crowded the segmented picker). The
    // picker lists Password/Key/None and displays `.keyboardInteractive` as
    // "Password"; the toggle flips `authMethod` between the two.
    private var authMethodPickerCases: [AuthType] {
        AuthType.allCases.filter { $0 != .keyboardInteractive }
    }
    private var targetMethodSelection: Binding<AuthType> {
        Binding(
            get: { authMethod == .keyboardInteractive ? .password : authMethod },
            set: { authMethod = $0 }
        )
    }
    private var targetUsesKeyboardInteractive: Binding<Bool> {
        Binding(
            get: { authMethod == .keyboardInteractive },
            set: { authMethod = $0 ? .keyboardInteractive : .password }
        )
    }
    private var sshAuthenticationSection: some View {
        Section("Authentication") {
            Group {
                TextField("Username", text: $username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                
                Picker("Method", selection: targetMethodSelection) {
                    ForEach(authMethodPickerCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if authMethod == .password || authMethod == .keyboardInteractive {
                    Toggle("Keyboard-Interactive (2FA / OTP)", isOn: targetUsesKeyboardInteractive)
                    if authMethod == .keyboardInteractive {
                        Text("The server will prompt for credentials, such as a one-time code. Used for 2FA/OTP and PAM logins.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        SecureField("Password", text: $password)
                        Toggle("Save Password", isOn: $savePassword)
                    }
                } else if authMethod == .key {
                    if sshKeyManager.savedKeys.isEmpty {
                        sshKeyEmptyState(
                            title: String(localized: "No SSH keys available"),
                            detail: String(localized: "Import a key to use key-based authentication.")
                        )
                    } else {
                        sshKeyPicker(title: String(localized: "SSH Key"), selection: $selectedKeyID)
                    }
                } else {
                    Text("No password or key required. Used for Tailscale SSH or other pre-authenticated connections.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        }
    }
    
    private var sshAdvancedSection: some View {
        Section("Advanced") {
            jumpHostDisclosure
                .themedRow()
            
            agentForwardingDisclosure
                .themedRow()

            // GPG agent forwarding rides on a Unix-socket forward
            // channel that only SSH and tssh expose; Mosh's UDP
            // transport can't carry it, so the option doesn't belong
            // on a Mosh connection.
            if connectionProtocol != .mosh {
                gpgAgentForwardingDisclosure
                    .themedRow()
            }

            portForwardingDisclosure
                .themedRow()
            
            terminalOptionsDisclosure
                .themedRow()
        }
    }
    
    private var jumpHostDisclosure: some View {
        DisclosureGroup(isExpanded: $isJumpHostExpanded) {
            JumpHostFormSection(
                useJumpHost: $useJumpHost,
                hostname: $jumpHostname,
                port: $jumpPort,
                username: $jumpUsername,
                authMethod: $jumpAuthMethod,
                password: $jumpPassword,
                savePassword: $saveJumpPassword,
                selectedKeyID: $jumpSelectedKeyID
            )
        } label: {
            advancedSectionLabel(
                title: String(localized: "Jump Host"),
                systemImage: "point.3.connected.trianglepath.dotted",
                summary: jumpHostSummaryText
            )
        }
    }
    
    private var agentForwardingDisclosure: some View {
        DisclosureGroup(isExpanded: $isAgentForwardingExpanded) {
            Toggle("Enable Agent Forwarding", isOn: $enableAgentForwarding.animation())
            
            if enableAgentForwarding {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval Mode")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Picker("Approval Mode", selection: $agentApprovalMode) {
                        ForEach(SSHAgentConfig.ApprovalMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    Text(agentApprovalMode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                
                if sshKeyManager.savedKeys.isEmpty {
                    sshKeyEmptyState(
                        title: String(localized: "No SSH keys available to forward"),
                        detail: String(localized: "Import a key before enabling agent forwarding.")
                    )
                } else {
                    Toggle("Forward All Keys", isOn: $agentForwardAllKeys)
                    
                    if !agentForwardAllKeys {
                        ForEach(sshKeyManager.savedKeys) { key in
                            Button(action: {
                                if agentSelectedKeyIDs.contains(key.id) {
                                    agentSelectedKeyIDs.remove(key.id)
                                } else {
                                    agentSelectedKeyIDs.insert(key.id)
                                }
                            }) {
                                HStack {
                                    Image(systemName: agentSelectedKeyIDs.contains(key.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(agentSelectedKeyIDs.contains(key.id) ? .accentColor : .secondary)
                                    Text(key.name)
                                    Spacer()
                                    Text(key.keyType.shortName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } label: {
            advancedSectionLabel(
                title: String(localized: "Agent Forwarding"),
                systemImage: "key",
                summary: agentForwardingSummaryText
            )
        }
    }

    @StateObject private var gpgKeyManager = GPGKeyManager.shared

    /// Shared row renderer for the GPG forwarding key picker. Used for
    /// both SSH-keys-promoted-to-GPG and imported-GPG-keys; the badge
    /// text + colour tells the user where the key came from.
    private func gpgKeyPickerRow(
        id: UUID,
        name: String,
        fingerprint: String,
        badge: String,
        badgeColor: Color
    ) -> some View {
        Button {
            if gpgSelectedKeyIDs.contains(id) {
                gpgSelectedKeyIDs.remove(id)
            } else {
                gpgSelectedKeyIDs.insert(id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: gpgSelectedKeyIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(gpgSelectedKeyIDs.contains(id) ? .accentColor : .secondary)
                Text(name)
                Text(badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.18))
                    .foregroundColor(badgeColor)
                    .clipShape(Capsule())
                Spacer()
                Text(fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var gpgAgentForwardingDisclosure: some View {
        DisclosureGroup(isExpanded: $isGPGAgentForwardingExpanded) {
            Toggle("Enable GPG Agent Forwarding", isOn: $enableGPGAgentForwarding.animation())

            if enableGPGAgentForwarding {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval Mode")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Picker("Approval Mode", selection: $gpgAgentApprovalMode) {
                        ForEach(GPGAgentConfig.ApprovalMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(gpgAgentApprovalMode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Socket Path")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("Remote Socket Path", text: $gpgRemoteSocketPath)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack(spacing: 8) {
                        Button("Home dir (default)") {
                            gpgRemoteSocketPath = "{HOME}/.gnupg/S.gpg-agent"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("XDG runtime dir") {
                            gpgRemoteSocketPath = "/run/user/{UID}/gnupg/S.gpg-agent"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("`{HOME}` and `{UID}` are resolved at connect time by probing the remote (`id -u` / `$HOME`). The remote `sshd` then `bind(2)`s the substituted absolute path, so its parent directory must exist and `AllowStreamLocalForwarding yes` (the sshd default) must be set in `sshd_config`. If the remote has its own gpg-agent, add `no-autostart` to its `~/.gnupg/gpg.conf` so it doesn't compete for the socket.\n\nOnly add `StreamLocalBindUnlink yes` to sshd_config if you hit `bind: address already in use` from a stale socket. It's server-wide and lets any new connection stomp an existing one, so concurrent sessions to the same path will disconnect each other.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                // Combined list of keys usable for GPG signing:
                //   * imported GPG keys (.gpg badge)
                //   * SSH keys with a cached keygrip (.ssh badge) —
                //     same Ed25519/ECDSA/RSA primitives that already
                //     produce SSH signatures also produce GPG-format
                //     signatures via SSHKeyGPGBridge.
                let gpgEligibleSSHKeys = sshKeyManager.savedKeys.filter { $0.gpgKeygripHex != nil }

                if gpgKeyManager.savedKeys.isEmpty && gpgEligibleSSHKeys.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No keys available for GPG forwarding")
                                .font(.subheadline)
                            Text("Import an SSH or GPG key first.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Toggle("Forward All Eligible Keys", isOn: $gpgForwardAllKeys)

                    if !gpgForwardAllKeys {
                        // SSH keys first — that's what most users have.
                        if !gpgEligibleSSHKeys.isEmpty {
                            Section {
                                ForEach(gpgEligibleSSHKeys) { key in
                                    gpgKeyPickerRow(
                                        id: key.id,
                                        name: key.name,
                                        fingerprint: key.colonFormattedFingerprint,
                                        badge: "SSH",
                                        badgeColor: .blue
                                    )
                                }
                            }
                        }
                        if !gpgKeyManager.savedKeys.isEmpty {
                            Section {
                                ForEach(gpgKeyManager.savedKeys) { key in
                                    gpgKeyPickerRow(
                                        id: key.id,
                                        name: key.name,
                                        fingerprint: key.shortPrimaryFingerprint,
                                        badge: "GPG",
                                        badgeColor: .purple
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            advancedSectionLabel(
                title: String(localized: "GPG Agent Forwarding"),
                systemImage: "lock.shield",
                summary: enableGPGAgentForwarding
                    ? String(localized: "Forwarding to \(gpgRemoteSocketPath)")
                    : String(localized: "Disabled")
            )
        }
    }

    private var portForwardingDisclosure: some View {
        DisclosureGroup(isExpanded: $isPortForwardingExpanded) {
            if portForwards.isEmpty {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundColor(.secondary)
                    Text("No port forwards configured")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(portForwards) { forward in
                    PortForwardRow(forward: forward) {
                        portForwards.removeAll { $0.id == forward.id }
                    }
                }
            }
            
            NavigationLink {
                AddPortForwardView { newForward in
                    let wasEmpty = portForwards.isEmpty
                    portForwards.append(newForward)
                    #if !targetEnvironment(macCatalyst)
                    if wasEmpty
                        && !locationDiaryManager.isConfigured
                        && !SettingsStore.shared.get(Settings.Connections.hasSeenPortForwardBackgroundPrompt) {
                        showPortForwardBackgroundAlert = true
                    }
                    #endif
                }
            } label: {
                Label("Add Port Forward", systemImage: "plus.circle")
            }

            #if !targetEnvironment(macCatalyst)
            if !portForwards.isEmpty && !locationDiaryManager.isConfigured {
                Text("Port forwards stop when the app is suspended. Enable Location Diary (Auto mode) in Privacy settings, or use iPad Split View.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        } label: {
            advancedSectionLabel(
                title: String(localized: "Port Forwarding"),
                systemImage: "arrow.left.arrow.right",
                summary: portForwardingSummaryText
            )
        }
    }
    
    /// The mode to display, persist, and connect with. Mosh can't run control
    /// mode, so it normalizes to regular regardless of the stored selection —
    /// this keeps an impossible Mosh+control combo from ever being saved.
    private var effectiveTmuxAutoMode: TmuxAutoMode {
        connectionProtocol == .mosh ? .regular : tmuxAutoMode
    }

    /// Bridges the stored `(enableTmux, tmuxAutoMode, enableHerdr, enableZmx)` fields to a
    /// single Picker. Control mode can't run over Mosh, so it's presented as
    /// regular there.
    private var tmuxLaunchSelection: Binding<TmuxLaunchSelection> {
        Binding(
            get: { TmuxLaunchSelection(tmuxEnabled: enableTmux, mode: effectiveTmuxAutoMode,
                                       herdrEnabled: enableHerdr, zmxEnabled: enableZmx) },
            set: { sel in
                enableTmux = sel.tmuxEnabled
                enableHerdr = sel.herdrEnabled
                enableZmx = sel.zmxEnabled
                if sel.tmuxEnabled { tmuxAutoMode = sel.mode }
            }
        )
    }

    private var terminalOptionsDisclosure: some View {
        DisclosureGroup(isExpanded: $isTerminalOptionsExpanded) {
            Picker("Auto-start multiplexer", selection: tmuxLaunchSelection) {
                Text("Off").tag(TmuxLaunchSelection.off)
                Text("tmux").tag(TmuxLaunchSelection.regular)
                if connectionProtocol != .mosh {
                    Text("tmux -CC (control)").tag(TmuxLaunchSelection.control)
                }
                Text("herdr").tag(TmuxLaunchSelection.herdr)
                Text("zmx").tag(TmuxLaunchSelection.zmx)
            }
            .pickerStyle(.menu)

            if tmuxLaunchSelection.wrappedValue == .control {
                Text("Start a tmux -CC control-mode gateway for session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if enableTmux {
                Text("Attach to or create tmux session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if enableHerdr {
                Text("Attach to or create herdr session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if enableZmx {
                Text("Attach to or create zmx session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch Command")
                    .font(.subheadline)
                TextEditor(text: $launchCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                Picker("Behavior", selection: $launchCommandMode) {
                    ForEach(SSHConfig.LaunchCommandMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(launchCommandMode == .initialCommandWithPTY
                     ? "Runs as the initial remote command with a PTY, like ssh -t host command."
                     : "Command sent as input after connecting. Runs inside tmux if enabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } label: {
            advancedSectionLabel(
                title: String(localized: "Terminal Options"),
                systemImage: "terminal",
                summary: terminalOptionsSummaryText
            )
        }
    }
    
    private var profilesConnectionContent: some View {
        VStack(spacing: 0) {
            compactOpenAsHeader
            
            InlineProfilesView(
                splitOption: $splitOption,
                navigationPath: $inlineProfilesPath,
                onProfileSelected: { profile, selectedSplitOption in
                    onProfileConnect?(profile, selectedSplitOption)
                },
                onCancel: {
                    if let onClose {
                        onClose()
                    } else {
                        close()
                    }
                }
            )
        }
    }
    
    private var browseConnectionContent: some View {
        VStack(spacing: 0) {
            compactOpenAsHeader
            
            SSHHostBrowseListContent(
                onHostSelected: { selection in
                    applyBrowseSelection(selection)
                    selectConnectionType(selection.serviceKind == .vnc ? .vnc : .ssh)
                },
                onDismiss: onClose
            )
        }
    }
    
    private var localShellConnectionContent: some View {
        VStack(spacing: 0) {
            compactOpenAsHeader
            
            Form {
                Section {
                    Group {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(localShellTitle)
                                .font(.headline)
                            
                            Text(localShellDescription)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .themedRow()
                }
            }
            .themedList()
#if !os(visionOS)
            .scrollDismissesKeyboard(.immediately)
#endif
        }
    }
    
    // Shared with the Screen Sharing form (SSHConnectionView+VNC.swift).
    var compactOpenAsHeader: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("Open As", selection: $splitOption) {
                    ForEach(SplitOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(sheetThemeColors?.background ?? Color(.systemGroupedBackground))
            
            Divider()
        }
    }
    
    @ViewBuilder
    private var connectionTypeSwitcher: some View {
#if os(visionOS)
        swiftUIConnectionTypeSwitcher
#else
        if needsIOS27ConnectionTypeTapWorkaround {
            ConnectionTypeIOS27ScrollHost(
                types: visibleConnectionTypes,
                selection: connectionType,
                selectedBackgroundColor: connectionTypeSelectedBackgroundColor,
                accentColor: sheetThemeColors?.accentColor ?? .accentColor,
                colorScheme: colorScheme,
                onSelect: selectConnectionType
            )
            .background(sheetThemeColors?.background ?? Color(.systemGroupedBackground))
        } else {
            swiftUIConnectionTypeSwitcher
        }
#endif
    }

    private var swiftUIConnectionTypeSwitcher: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleConnectionTypes, id: \.self) { type in
                        connectionTypeTabButton(for: type)
                            .id(type)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear {
                proxy.scrollTo(connectionType, anchor: .center)
            }
            .onChange(of: connectionType) { _, newType in
                withAnimation(TabAnimation.selection) {
                    proxy.scrollTo(newType, anchor: .center)
                }
            }
        }
        .modifier(GlassEffectContainerModifier())
        .background(sheetThemeColors?.background ?? Color(.systemGroupedBackground))
    }

    private var connectionTypeSelectedBackgroundColor: Color {
        sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemBackground)
    }

    /// The iOS 27 SDK is not required to build this project yet, so gate the
    /// temporary forward-compatibility workaround using the runtime version.
    private var needsIOS27ConnectionTypeTapWorkaround: Bool {
#if os(visionOS) || targetEnvironment(macCatalyst)
        false
#else
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
#endif
    }

    private func connectionTypeTabButton(for type: ConnectionType) -> some View {
        let isSelected = connectionType == type

        return Button {
            selectConnectionType(type)
        } label: {
            connectionTypeTabLabel(for: type, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func connectionTypeTabLabel(
        for type: ConnectionType,
        isSelected: Bool
    ) -> some View {
        Label(type.displayName, systemImage: type.iconName)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(
                GlassTabBackgroundModifier(
                    isSelected: isSelected,
                    selectedBackgroundColor: connectionTypeSelectedBackgroundColor,
                    unselectedBackgroundColor: .clear,
                    id: connectionTypeID(for: type),
                    namespace: connectionTypeTabNamespace,
                    isLightTheme: colorScheme == .light,
                    isHovered: false
                )
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .clipShape(Capsule())
    }

    private func connectionTypeID(for type: ConnectionType) -> UUID {
        switch type {
        case .profiles: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA001")!
        case .ssh: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA002")!
        case .local: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA003")!
        case .browse: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA004")!
        case .kubernetes: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA005")!
        case .console: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA006")!
        case .vnc: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA007")!
        }
    }
    
    private var quickConnectHeaderLine: some View {
        HStack(spacing: 8) {
            if !isQuickConnectAtDefaultState {
                Image(systemName: statusLineSymbolName)
                    .font(.caption)
                    .foregroundStyle(isFormValid ? Color.secondary : Color.orange)
            }
            
            Text(quickConnectHeaderText)
                .font(isQuickConnectAtDefaultState ? .subheadline : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // Thin wrappers over the shared key sub-views (extracted alongside
    // JumpHostFormSection) so existing call sites stay unchanged.
    private func sshKeyEmptyState(title: String, detail: String) -> some View {
        SSHKeyEmptyStateView(title: title, detail: detail)
    }

    private func sshKeyPicker(title: String, selection: Binding<UUID?>) -> some View {
        SSHKeyPickerView(title: title, selection: selection)
    }
    
    private func advancedSectionLabel(title: String, systemImage: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
            
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private var connectionPreviewText: String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let portNumber = Int(port) ?? 22
        
        if user.isEmpty || host.isEmpty {
            return "user@host"
        }
        
        return portNumber == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(portNumber)"
    }
    
    private var compactStatusText: String {
        var parts: [String] = []
        
        let preview = connectionPreviewText
        if preview != "user@host" {
            parts.append(preview)
        }
        
        let supportingText = selectedSuggestionDetail ?? compactReadinessText
        if !supportingText.isEmpty {
            parts.append(supportingText)
        }
        
        return parts.joined(separator: " • ")
    }
    
    private var quickConnectHeaderText: String {
        isQuickConnectAtDefaultState ? String(localized: "Quick Connect") : compactStatusText
    }
    
    private var isQuickConnectAtDefaultState: Bool {
        quickConnectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        errorMessage == nil &&
        selectedSuggestionDetail == nil
    }
    
    private var statusLineSymbolName: String {
        if let errorMessage, !errorMessage.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        
        return isFormValid ? "checkmark.circle" : "info.circle"
    }
    
    private var connectionReadinessText: String {
        if isFormValid {
            return useJumpHost ? "Ready to connect through a jump host." : "Ready to connect."
        }
        
        if hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a host to continue."
        }
        
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a username to continue."
        }
        
        if !isPortValid {
            return "Enter a valid port number."
        }
        
        if authMethod == .password && password.isEmpty {
            return "Enter a password or switch auth method."
        }
        
        if authMethod == .key && selectedKeyID == nil {
            return "Select an SSH key to continue."
        }
        
        return "Complete the remaining connection details."
    }
    
    private var compactReadinessText: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        
        if isFormValid {
            return useJumpHost ? String(localized: "Ready via jump host") : String(localized: "Ready")
        }
        
        if hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Add a host")
        }
        
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Add a username")
        }
        
        if !isPortValid {
            return String(localized: "Check the port")
        }
        
        if authMethod == .password && password.isEmpty {
            return String(localized: "Enter a password")
        }
        
        if authMethod == .key && selectedKeyID == nil {
            return String(localized: "Select an SSH key")
        }
        
        return String(localized: "Complete the remaining details")
    }
    
    private var jumpHostSummaryText: String {
        guard useJumpHost else { return String(localized: "Optional bastion or proxy host") }
        
        let host = jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if host.isEmpty || user.isEmpty {
            return String(localized: "Jump host enabled")
        }
        
        let portNumber = Int(jumpPort) ?? 22
        return portNumber == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(portNumber)"
    }
    
    private var agentForwardingSummaryText: String {
        guard enableAgentForwarding else { return String(localized: "Forward keys only when needed") }
        return agentForwardAllKeys
        ? String(localized: "Forwarding all available keys")
        : String(localized: "Forwarding \(agentSelectedKeyIDs.count) selected keys")
    }
    
    private var portForwardingSummaryText: String {
        if portForwards.isEmpty {
            return String(localized: "Add local, remote, or dynamic forwards")
        }
        
        if portForwards.count == 1, let forward = portForwards.first {
            return forward.displayString
        }
        
        return String(localized: "\(portForwards.count) forwards configured")
    }
    
    private var terminalOptionsSummaryText: String {
        let trimmedCommand = launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if enableTmux && !trimmedCommand.isEmpty {
            return launchCommandMode == .initialCommandWithPTY
            ? String(localized: "Initial command with PTY")
            : String(localized: "tmux enabled, launch command configured")
        }
        
        if enableTmux {
            return String(localized: "tmux starts automatically")
        }

        if enableHerdr && !trimmedCommand.isEmpty {
            return launchCommandMode == .initialCommandWithPTY
            ? String(localized: "Initial command with PTY")
            : String(localized: "herdr enabled, launch command configured")
        }

        if enableHerdr {
            return String(localized: "herdr attaches automatically")
        }

        if enableZmx && !trimmedCommand.isEmpty {
            return launchCommandMode == .initialCommandWithPTY
            ? String(localized: "Initial command with PTY")
            : String(localized: "zmx enabled, launch command configured")
        }

        if enableZmx {
            return String(localized: "zmx attaches automatically")
        }

        if !trimmedCommand.isEmpty {
            return launchCommandMode == .initialCommandWithPTY
            ? String(localized: "Initial command with PTY")
            : String(localized: "Launch command configured")
        }

        return String(localized: "tmux and launch command are optional")
    }
    
    /// The SSH and Screen Sharing tabs each have their own host field, so
    /// switching between them would otherwise drop the host already typed.
    private func carryEndpointBetweenTabs(from oldType: ConnectionType, to newType: ConnectionType) {
        switch (oldType, newType) {
        case (.ssh, .vnc):
            var destination = vncForm.endpoint
            endpointCarryOver.carry(from: sshEndpoint, into: &destination, side: .screenSharing)
            vncForm.endpoint = destination
        case (.vnc, .ssh):
            var destination = sshEndpoint
            endpointCarryOver.carry(from: vncForm.endpoint, into: &destination, side: .sshFamily)
            applySSHEndpoint(destination)
        default:
            break
        }
    }

    /// The SSH fields in the shared endpoint shape.
    private var sshEndpoint: ConnectionEndpoint {
        ConnectionEndpoint(
            host: hostname,
            username: username,
            usesJumpHost: useJumpHost,
            jumpHost: jumpHostname,
            jumpPort: jumpPort,
            jumpUsername: jumpUsername,
            jumpAuthMethod: jumpAuthMethod,
            jumpKeyID: jumpSelectedKeyID,
            hasHostBoundSecret: !password.isEmpty || !jumpPassword.isEmpty
        )
    }

    private func applySSHEndpoint(_ endpoint: ConnectionEndpoint) {
        hostname = endpoint.host
        username = endpoint.username

        useJumpHost = endpoint.usesJumpHost
        guard endpoint.usesJumpHost else { return }
        isJumpHostExpanded = true
        jumpHostname = endpoint.jumpHost
        jumpPort = endpoint.jumpPort
        jumpUsername = endpoint.jumpUsername
        jumpAuthMethod = endpoint.jumpAuthMethod
        jumpSelectedKeyID = endpoint.jumpKeyID
    }

    private func selectConnectionType(_ type: ConnectionType) {
        if connectionType == .ssh && type != .ssh {
            // Resign before removing Quick Connect from the hierarchy. This is
            // separate from tap recognition, but keeps the responder handoff
            // ordered when the newly selected destination contains fields of
            // its own.
            isQuickConnectFocused = false
        }

        withAnimation(TabAnimation.selection) {
            connectionType = type
            lastConnectionTypeRaw = type.rawValue

            if type != .profiles {
                inlineProfilesPath = []
            }
        }
    }
    
    private func handleConnectionViewAppear() {
        guard !hasInitialized else { return }
        hasInitialized = true
        
        isQuickConnectFocused = true
        
        if let defaultKeyID = sshKeyManager.primaryDefaultKeyID,
           sshKeyManager.findKey(id: defaultKeyID) != nil {
            authMethod = .key
            selectedKeyID = defaultKeyID
            jumpSelectedKeyID = defaultKeyID
        }
        
        if let config = initialConfig {
            hostname = config.host
            port = "\(config.port)"
            username = config.username
            
            switch config.authMethod {
            case .password:
                authMethod = .password
                password = ""
            case .savedPassword:
                authMethod = .password
                password = ""
            case .key(let keyID):
                authMethod = .key
                selectedKeyID = keyID
            case .keyboardInteractive:
                authMethod = .keyboardInteractive
            case .none:
                authMethod = .none
            case .unknown:
                // Auth method from a newer app version; show as None so the form
                // is usable. The original value is preserved unless the user saves.
                authMethod = .none
            }
            
            enableTmux = config.tmuxAutoEnable
            tmuxAutoMode = config.tmuxAutoMode
            enableHerdr = config.herdrAutoEnable
            enableZmx = config.zmxAutoEnable
            launchCommand = config.launchCommand ?? ""
            launchCommandMode = config.launchCommandMode
            restoreCarriedOverrides(terminalType: config.terminalType,
                                    multiplexerSessionName: config.multiplexerSessionName,
                                    host: config.host,
                                    username: config.username,
                                    port: config.port)
            errorMessage = "Authentication failed. Please check your credentials."
        }
        
        if let selection = initialBrowseSelection {
            applyBrowseSelection(selection)
        }
    }
    
    private func handleConnectionViewTask() async {
#if targetEnvironment(macCatalyst)
        await withCheckedContinuation { continuation in
            HelperConnection.shared.isHelperRunning { isRunning in
                Task { @MainActor in
                    helperAvailable = isRunning
                    continuation.resume()
                }
            }
        }
#endif
        
        cachedConsoleCapableAccounts = computeConsoleCapableAccounts()
        
        if let config = initialConfig, authMethod == .password {
            do {
                let savedPassword = try await SSHPasswordManager.shared.loadPassword(
                    host: config.host,
                    port: config.port,
                    username: config.username
                )
                password = savedPassword
            } catch {
                // No saved password or load failed - leave empty for user to enter
            }
        }
    }
    
    // MARK: - Computed Properties
    
    /// Whether the form has enough data to save as a profile (host and username minimum)
    private var canSaveAsProfile: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var isFormValid: Bool {
        // Local shells are always valid
        if connectionType == .local {
            return true
        }
        
        // Kubernetes validation
        if connectionType == .kubernetes {
            return selectedCluster != nil && selectedNode != nil && selectedNode?.isReady == true
        }
        
        // Console/Browse connections happen by tapping an instance directly (no Connect button)
        if connectionType == .console || connectionType == .browse {
            return true
        }

        // Screen Sharing validation
        if connectionType == .vnc {
            return isVNCFormValid
        }

        // SSH target validation
        let basicValid = !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isPortValid
        
        // Check target auth-specific requirements
        let targetAuthValid: Bool
        switch authMethod {
        case .password:
            targetAuthValid = basicValid && !password.isEmpty
        case .key:
            targetAuthValid = basicValid && selectedKeyID != nil
        case .keyboardInteractive:
            targetAuthValid = basicValid  // Server drives the prompts; no field required
        case .none:
            targetAuthValid = basicValid  // No additional auth validation needed
        }
        
        // If using jump host, validate jump host fields too
        if useJumpHost {
            let jumpBasicValid = !jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            isJumpPortValid
            
            let jumpAuthValid: Bool
            switch jumpAuthMethod {
            case .password:
                jumpAuthValid = jumpBasicValid && !jumpPassword.isEmpty
            case .key:
                jumpAuthValid = jumpBasicValid && jumpSelectedKeyID != nil
            case .keyboardInteractive:
                jumpAuthValid = jumpBasicValid  // Server drives the prompts; no field required
            case .none:
                jumpAuthValid = jumpBasicValid  // No additional auth validation needed
            }
            
            return targetAuthValid && jumpAuthValid
        }
        
        return targetAuthValid
    }
    
    private var isJumpPortValid: Bool {
        if let portNum = Int(jumpPort), portNum > 0 && portNum <= 65535 {
            return true
        }
        return false
    }
    
    private var isPortValid: Bool {
        if let portNum = Int(port), portNum > 0 && portNum <= 65535 {
            return true
        }
        return false
    }
    
    /// Build a history entry from current form fields for profile creation
    private func buildHistoryEntryFromForm() -> SSHConnectionHistoryEntry {
        let authType: SSHAuthType
        switch authMethod {
        case .password:
            authType = savePassword ? .savedPassword : .password
        case .key:
            let keyID = selectedKeyID ?? UUID()
            let fingerprint = SSHKeyManager.shared.findKey(id: keyID)?.fingerprint
            authType = .key(keyID, fingerprint: fingerprint)
        case .keyboardInteractive:
            authType = .keyboardInteractive
        case .none:
            authType = .none
        }
        
        let jumpAuthType: SSHAuthType?
        if useJumpHost {
            switch jumpAuthMethod {
            case .password:
                jumpAuthType = saveJumpPassword ? .savedPassword : .password
            case .key:
                let keyID = jumpSelectedKeyID ?? UUID()
                let fingerprint = SSHKeyManager.shared.findKey(id: keyID)?.fingerprint
                jumpAuthType = .key(keyID, fingerprint: fingerprint)
            case .keyboardInteractive:
                jumpAuthType = .keyboardInteractive
            case .none:
                jumpAuthType = SSHAuthType.none
            }
        } else {
            jumpAuthType = nil
        }
        
        let agentConfig: SSHAgentConfig? = enableAgentForwarding
        ? SSHAgentConfig(
            enabled: true,
            approvalMode: agentApprovalMode,
            forwardedKeyIDs: agentForwardAllKeys ? [] : agentSelectedKeyIDs
        )
        : nil

        // Always emit an explicit config — passing nil here used to
        // mean "skip update", which silently re-enabled forwarding on
        // entries that had it on. Now nil → cleared, .disabled →
        // cleared, enabled → stored. Pass `.disabled` when off so
        // history accurately reflects the current intent.
        // Mosh's UDP transport can't carry the Unix-socket forward GPG
        // rides on; the UI hides the toggle in that mode but the
        // backing @State doesn't reset, so a user who enabled GPG and
        // then switched to Mosh would otherwise persist `enabled: true`
        // into history/profile. Force-disable here to keep the stored
        // config honest about what the connection can actually do.
        let gpgAgentConfigForEntry: GPGAgentConfig = (enableGPGAgentForwarding && connectionProtocol != .mosh)
            ? GPGAgentConfig(
                enabled: true,
                approvalMode: gpgAgentApprovalMode,
                forwardedKeyIDs: gpgForwardAllKeys ? [] : gpgSelectedKeyIDs,
                remoteSocketPath: gpgRemoteSocketPath.trimmingCharacters(in: .whitespaces).isEmpty
                    ? GPGAgentConfig.defaultRemoteSocketPath
                    : gpgRemoteSocketPath.trimmingCharacters(in: .whitespaces)
            )
            : .disabled

        // Build key resolution hints for cross-device key matching
        var keyIDs: [UUID] = []
        if let keyID = authType.keyID { keyIDs.append(keyID) }
        if let jumpKeyID = jumpAuthType?.keyID { keyIDs.append(jumpKeyID) }
        let hints = keyIDs.isEmpty ? nil : KeyResolutionHint.hintsDict(forKeyIDs: keyIDs)

        return SSHConnectionHistoryEntry(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            host: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port) ?? 22,
            authType: authType,
            connectionProtocol: connectionProtocol,
            jumpHost: useJumpHost ? jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            jumpPort: useJumpHost ? (Int(jumpPort) ?? 22) : nil,
            jumpUsername: useJumpHost ? jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            jumpAuthType: jumpAuthType,
            hssShorthand: currentHSSShorthand,
            agentConfig: agentConfig,
            gpgAgentConfig: gpgAgentConfigForEntry,
            portForwardConfig: portForwards.isEmpty ? nil : PortForwardConfig(forwards: portForwards),
            tmuxAutoEnable: enableTmux ? true : nil,
            tmuxAutoMode: enableTmux ? effectiveTmuxAutoMode : nil,
            herdrAutoEnable: enableHerdr ? true : nil,
            zmxAutoEnable: enableZmx ? true : nil,
            launchCommand: launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : launchCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            launchCommandMode: launchCommandMode,
            terminalType: terminalTypeOverride(
                forHost: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(port) ?? 22),
            multiplexerSessionName: multiplexerSessionNameOverride(
                forHost: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(port) ?? 22),
            keyResolutionHints: hints
        )
    }
    
    // MARK: - Actions
    
    private func connect() {
        // Clear previous errors
        errorMessage = nil
        
        // Handle local shell
#if targetEnvironment(macCatalyst)
        if connectionType == .local {
            isConnecting = true
            HelperConnection.shared.isHelperRunning { isRunning in
                Task { @MainActor in
                    guard isRunning else {
                        isConnecting = false
                        errorMessage = "Ghostty Helper is not running. Please launch the helper app to use local shells."
                        return
                    }
                    
                    onConnect(nil, splitOption)
                    close()
                }
            }
            return
        }
#else
        if connectionType == .local {
            // Call callback with nil config for local shell
            onConnect(nil, splitOption)
            close()
            return
        }
#endif
        
        // Handle Kubernetes node shell
        if connectionType == .kubernetes {
            connectKubernetes()
            return
        }

        // Handle Screen Sharing (VNC)
        if connectionType == .vnc {
            connectVNC()
            return
        }
        
        // Console connections are handled directly by tapping an instance
        // (Connect button is hidden for console mode)
        
        // SSH connection handling
        // Validate port
        guard let portNum = Int(port), portNum > 0 && portNum <= 65535 else {
            errorMessage = "Invalid port number. Must be between 1 and 65535."
            return
        }
        
        // Create SSH config based on auth method
        let trimmedHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Lookup cached IP from history for .local hostnames
        let cachedIP: String?
        if trimmedHost.hasSuffix(".local") {
            cachedIP = historyManager.entries.first(where: {
                $0.host == trimmedHost && $0.username == trimmedUsername && $0.port == portNum
            })?.cachedIP
        } else {
            cachedIP = nil
        }
        
        // Build jump host config if enabled (shared builder — same fields
        // and validation messages as the extracted jump form section)
        let jumpConfig: SSHConfig.JumpHostConfig?
        do {
            jumpConfig = try JumpHostFormSection.buildJumpHostConfig(
                useJumpHost: useJumpHost,
                hostname: jumpHostname,
                port: jumpPort,
                username: jumpUsername,
                authMethod: jumpAuthMethod,
                password: jumpPassword,
                selectedKeyID: jumpSelectedKeyID,
                sshKeyManager: sshKeyManager
            )
        } catch {
            errorMessage = (error as? JumpHostFormSection.BuildError)?.message ?? error.localizedDescription
            return
        }
        
        // Build agent config if enabled
        let agentConfig: SSHAgentConfig
        if enableAgentForwarding {
            let keyIDs = agentForwardAllKeys ? Set<UUID>() : agentSelectedKeyIDs
            agentConfig = SSHAgentConfig(
                enabled: true,
                approvalMode: agentApprovalMode,
                forwardedKeyIDs: keyIDs
            )
        } else {
            agentConfig = .disabled
        }

        // Build GPG agent config if enabled. Assigned to
        // config.gpgAgentConfig below after the SSHConfig is
        // constructed — the convenience initializers don't accept it
        // yet, but the stored property defaults to .disabled, so a
        // direct mutation is sufficient.
        let gpgConfig: GPGAgentConfig
        // Same gating as the history entry above — Mosh can't forward
        // GPG, so force-disable regardless of the (hidden) toggle.
        if enableGPGAgentForwarding && connectionProtocol != .mosh {
            let trimmedPath = gpgRemoteSocketPath.trimmingCharacters(in: .whitespaces)
            gpgConfig = GPGAgentConfig(
                enabled: true,
                approvalMode: gpgAgentApprovalMode,
                forwardedKeyIDs: gpgForwardAllKeys ? [] : gpgSelectedKeyIDs,
                remoteSocketPath: trimmedPath.isEmpty
                    ? GPGAgentConfig.defaultRemoteSocketPath
                    : trimmedPath
            )
        } else {
            gpgConfig = .disabled
        }
        
        // Build port forward config
        let portForwardConfig = portForwards.isEmpty ? PortForwardConfig.none : PortForwardConfig(forwards: portForwards)
        
        // Every auth variant builds the same SSHConfig fields; only the auth
        // method (and key fallbacks) differ. Resolve those, then build once.
        let trimmedLaunchCommand = launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAuthMethod: SSHConfig.AuthMethod
        var fallbackKeyIDs: [UUID]? = nil

        switch authMethod {
        case .password:
            resolvedAuthMethod = .password(password)

        case .key:
            guard let keyID = selectedKeyID else {
                errorMessage = "Please select an SSH key"
                return
            }
            // Verify key still exists
            guard sshKeyManager.findKey(id: keyID) != nil else {
                errorMessage = "Selected SSH key not found. Please select another key."
                return
            }
            resolvedAuthMethod = .key(keyID)
            // Fallback keys = remaining defaults (excluding the selected key)
            let fallbackIDs = sshKeyManager.defaultKeyIDs.filter { $0 != keyID }
            fallbackKeyIDs = fallbackIDs.isEmpty ? nil : fallbackIDs

        case .none:
            resolvedAuthMethod = .none

        case .keyboardInteractive:
            resolvedAuthMethod = .keyboardInteractive
        }

        var config = SSHConfig(
            host: trimmedHost,
            port: portNum,
            username: trimmedUsername,
            authMethod: resolvedAuthMethod,
            cachedIP: cachedIP,
            jumpHost: jumpConfig,
            hssShorthand: currentHSSShorthand,
            cloudInstanceLabel: selectedCloudInstanceLabel,
            agentConfig: agentConfig,
            portForwardConfig: portForwardConfig,
            tmuxAutoEnable: enableTmux,
            tmuxAutoMode: effectiveTmuxAutoMode,
            launchCommand: trimmedLaunchCommand.isEmpty ? nil : trimmedLaunchCommand,
            launchCommandMode: launchCommandMode
        )
        config.fallbackKeyIDs = fallbackKeyIDs
        config.herdrAutoEnable = enableHerdr
        config.zmxAutoEnable = enableZmx

        // Apply the GPG agent config after the SSHConfig is built —
        // the convenience initializers above don't carry it.
        config.gpgAgentConfig = gpgConfig

        // Quick Connect has no TERM or session-name field; these carry the
        // overrides forward when the form was populated from a history entry or
        // a profile, so a reconnect doesn't silently drop them. Applied only
        // when they were saved for the endpoint actually being connected to.
        config.terminalType = terminalTypeOverride(forHost: trimmedHost,
                                                   username: trimmedUsername,
                                                   port: portNum)
        config.multiplexerSessionName = multiplexerSessionNameOverride(forHost: trimmedHost,
                                                                      username: trimmedUsername,
                                                                      port: portNum)

        // Validate config
        guard config.isValid else {
            errorMessage = "Invalid connection details. Please check all fields."
            return
        }
        
        // Start connecting
        isConnecting = true
        
        // Save passwords to Keychain if requested
        if authMethod == .password && savePassword && !password.isEmpty {
            // Don't block connection on password save failure
            _ = try? SSHPasswordManager.shared.savePassword(
                password,
                host: trimmedHost,
                port: portNum,
                username: trimmedUsername
            )
        }
        
        // Save jump host password if requested
        if useJumpHost && jumpAuthMethod == .password && saveJumpPassword && !jumpPassword.isEmpty,
           let jumpPortNum = Int(jumpPort) {
            let trimmedJumpHost = jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedJumpUsername = jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            // Don't block connection on password save failure
            _ = try? SSHPasswordManager.shared.savePassword(
                jumpPassword,
                host: trimmedJumpHost,
                port: jumpPortNum,
                username: trimmedJumpUsername
            )
        }
        
        // Preserve the profile's theme and provenance when its populated form opens.
        if var profile = quickConnectProfile,
           profile.sshConfig.host == config.host,
           profile.sshConfig.username == config.username,
           profile.connectionProtocol == connectionProtocol,
           let onProfileConnect {
            profile.sshConfig = config
            onProfileConnect(profile, splitOption)
            close()
            return
        }

        // Call the appropriate connection callback based on connection type
        if connectionProtocol == .mosh, let moshCallback = onMoshConnect {
            // Create MoshConfig from SSHConfig
            let moshConfig = MoshConfig(sshConfig: config)
            moshCallback(moshConfig, splitOption)
        } else if connectionProtocol == .trzsz, let trzszCallback = onTrzszConnect {
            // Create TrzszConfig from SSHConfig
            let trzszConfig = TrzszConfig(sshConfig: config, transportMode: .preferred)
            trzszCallback(trzszConfig, splitOption)
        } else {
            // Standard SSH connection
            onConnect(config, splitOption)
        }
        
        // Dismiss the current presentation (sheet or sidebar).
        close()
    }
    
    private func handleQuickConnect() {
        // Fields are already filled by real-time parsing from .onChange
        // Just validate and connect

        // vnc:// text already switched to the Screen Sharing form
        if connectionType == .vnc {
            if isVNCFormValid {
                connectVNC()
            }
            return
        }

        // Validate hostname
        if hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Please enter a hostname"
            return
        }
        
        // Validate username
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = String(localized: "Please enter a username (format: user@hostname)", comment: "SSH connect: missing username validation error")
            return
        }
        
        // Try to restore auth method from history if not already set by Tab completion
        if authMethod == .password && password.isEmpty {
            // Look for matching entry to restore auth method
            let portNum = Int(port) ?? 22
            let matchingEntry = historyManager.entries.first {
                $0.host == hostname &&
                $0.username == username &&
                $0.port == portNum
            }
            
            if let entry = matchingEntry {
                handleSuggestionAccepted(entry)
            }
        }
        
        // Attempt to connect
        connect()
    }
    
    /// Normalized identity of the destination a TERM override belongs to, or
    /// nil when there is no host to speak of.
    ///
    /// Username and port are part of the identity because an override is
    /// per-connection: `user@host:22` and `other@host:2222` are different
    /// destinations that happen to share a hostname. The host is lowercased
    /// because DNS is case-insensitive, so retyping it in different case is the
    /// same server and must not discard the override.
    private func endpointIdentity(host: String, username: String, port: Int) -> String? {
        let normalizedHost = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalizedHost.isEmpty else { return nil }
        // Username case is preserved: POSIX accounts are case-sensitive.
        return "\(username)@\(normalizedHost):\(port)"
    }

    /// Identity of whatever the form's target fields currently describe. Only
    /// meaningful once host, username, and port have all been applied.
    private var currentEndpointIdentity: String? {
        endpointIdentity(host: hostname, username: username, port: Int(port) ?? 22)
    }

    /// Restores a connection's carried overrides and records which destination
    /// they belong to.
    private func restoreCarriedOverrides(terminalType value: String?,
                                         multiplexerSessionName sessionName: String?,
                                         host: String, username: String, port: Int) {
        terminalType = value ?? ""
        multiplexerSessionName = sessionName ?? ""
        carriedOverrideEndpoint = endpointIdentity(host: host, username: username, port: port)
    }

    /// The TERM override to apply to the connection being built, or nil when
    /// the stored override belongs to a different destination.
    ///
    /// The ownership check is the guard that actually matters, and it deliberately sits at the
    /// point of consumption rather than at each restore site. Restores happen
    /// from several places and some of them match loosely — the cloud-instance
    /// and local-network branches look up history by hostname alone, so a
    /// suggestion for `deploy@host:2222` can legitimately land on the history
    /// entry for `root@host:22` in order to recover its key. That is the right
    /// behavior for auth, but the TERM override belongs to the exact endpoint
    /// it was saved for. Checking here means every path, including ones added
    /// later, is covered without having to tighten each match.
    private func terminalTypeOverride(forHost host: String, username: String, port: Int) -> String? {
        guard !terminalType.isEmpty,
              ownsCarriedOverrides(host: host, username: username, port: port) else {
            return nil
        }
        return terminalType
    }

    /// The multiplexer session override to apply, guarded by the same endpoint
    /// ownership rule as the TERM override above.
    private func multiplexerSessionNameOverride(forHost host: String, username: String, port: Int) -> String? {
        guard !multiplexerSessionName.isEmpty,
              ownsCarriedOverrides(host: host, username: username, port: port) else {
            return nil
        }
        return multiplexerSessionName
    }

    private func ownsCarriedOverrides(host: String, username: String, port: Int) -> Bool {
        guard let owner = carriedOverrideEndpoint else { return false }
        return owner == endpointIdentity(host: host, username: username, port: port)
    }

    /// Drops the carried overrides unless they belong to `endpoint`.
    ///
    /// Deliberately keyed on the destination rather than on "the text changed":
    /// several paths (profile acceptance, browse selection, HSS expansion) set
    /// `quickConnectText` programmatically right before restoring an override,
    /// so a change-triggered clear would race them and throw the override away.
    /// Comparing identities is order-independent, and it still catches the case
    /// that matters — retargeting restored overrides at a different
    /// connection, which would otherwise connect a legacy host with an
    /// unsupported TERM, or attach to another host's session, and record that
    /// in history.
    private func dropCarriedOverridesIfNotFor(_ endpoint: String?) {
        guard carriedOverrideEndpoint != endpoint else { return }
        terminalType = ""
        multiplexerSessionName = ""
        carriedOverrideEndpoint = nil
    }

    private func updateFieldsFromQuickConnect(_ text: String) {
        // Clear suggestion detail and cloud label when user types (unless Tab-completed)
        // These will be set again if a suggestion is accepted
        selectedSuggestionDetail = nil
        selectedCloudInstanceLabel = nil

        // vnc://host[:port] switches to the Screen Sharing form
        if let vncTarget = Self.parseVNCQuickConnect(text) {
            // Screen Sharing has no TERM or multiplexer, and the form has left
            // the SSH target behind entirely, so the overrides can never apply.
            dropCarriedOverridesIfNotFor(nil)
            if !vncTarget.host.isEmpty {
                applyVNCTarget(hostname: vncTarget.host, port: vncTarget.port)
            }
            return
        }

        // Check for protocol prefix and update protocol toggle
        let textLower = text.lowercased()
        var effectiveText = text
        if textLower.hasPrefix("mosh ") {
            connectionProtocol = .mosh
            effectiveText = String(text.dropFirst(5))  // Remove "mosh " prefix
        } else if textLower.hasPrefix("trzsz ") || textLower.hasPrefix("tssh ") {
            connectionProtocol = .trzsz
            effectiveText = String(text.dropFirst(textLower.hasPrefix("trzsz ") ? 6 : 5))  // Remove prefix
        } else if textLower.hasPrefix("ssh ") {
            connectionProtocol = .ssh
            effectiveText = String(text.dropFirst(4))  // Remove "ssh " prefix
        }
        
        // Check for HSS shorthand (starts with "!")
        if HSSConfigManager.isHSSShorthand(effectiveText) {
            // The shorthand sets host, username, and port, so the form's fields
            // are the resolved destination by the time this runs.
            updateFieldsFromHSS(effectiveText)
            dropCarriedOverridesIfNotFor(currentEndpointIdentity)
            return
        }
        
        // Clear HSS shorthand when not using HSS
        currentHSSShorthand = nil
        
        // Parse the quick connect text with jump host support
        let parsed = QuickConnectParser.parseWithJumpHost(effectiveText)
        
        // Update target fields
        if let host = parsed.host, !host.isEmpty {
            hostname = host
        } else {
            hostname = ""
        }

        username = parsed.username ?? ""

        if let parsedPort = parsed.port {
            port = "\(parsedPort)"
        } else {
            port = "22"
        }

        // Only now do host, username, and port all describe the new target, so
        // this is the earliest point the override's identity can be judged.
        dropCarriedOverridesIfNotFor(currentEndpointIdentity)

        // Update jump host fields if present in quick connect
        if parsed.hasJumpHost {
            useJumpHost = true
            jumpHostname = parsed.jumpHost ?? ""
            jumpUsername = parsed.jumpUsername ?? ""
            if let parsedJumpPort = parsed.jumpPort {
                jumpPort = "\(parsedJumpPort)"
            } else {
                jumpPort = "22"
            }
            // Default jump host to same key auth as main connection
            if authMethod == .key && jumpSelectedKeyID == nil {
                jumpAuthMethod = .key
                jumpSelectedKeyID = selectedKeyID
            }
        } else if !text.lowercased().contains(" via ") {
            // Only reset jump host if user isn't typing "via" syntax
            // This prevents clearing fields while user types
            if jumpHostname.isEmpty && jumpUsername.isEmpty {
                useJumpHost = false
            }
        }
    }
    
    /// Update fields from HSS shorthand expansion
    private func updateFieldsFromHSS(_ text: String) {
        // Clear any previous error
        errorMessage = nil
        
        // Don't process if just "!" with nothing after
        guard text.count > 1 else {
            currentHSSShorthand = nil
            return
        }
        
        // Extract the shorthand (without "!")
        let shorthand = String(text.dropFirst())
        
        do {
            // Try to resolve the HSS shorthand
            guard let resolution = try HSSConfigManager.shared.resolve(text) else {
                // No pattern matched - don't show error while typing
                currentHSSShorthand = nil
                return
            }
            
            // Track the HSS shorthand for history
            currentHSSShorthand = shorthand
            
            // Populate target fields
            hostname = resolution.host
            port = "\(resolution.port)"
            if let user = resolution.username {
                username = user
            }
            
            // Populate jump host if detected from ProxyCommand
            if resolution.hasJumpHost {
                useJumpHost = true
                jumpHostname = resolution.jumpHost ?? ""
                jumpPort = "\(resolution.jumpPort)"
                if let jUser = resolution.jumpUsername {
                    jumpUsername = jUser
                } else {
                    // Default to current system user
                    jumpUsername = UserPreferences.effectiveUsername
                }
                // Default jump host to same key auth as main connection
                if authMethod == .key {
                    jumpAuthMethod = .key
                    jumpSelectedKeyID = selectedKeyID
                }
            }
            
        } catch {
            // Don't show error while typing - just leave fields as-is
            // Error will be shown if user tries to connect
            currentHSSShorthand = nil
        }
    }
    
    private func handleSuggestionAccepted(_ entry: SSHConnectionHistoryEntry) {
        // Restore protocol from history if stored
        // Don't override with default if nil - preserve any value detected from text prefix
        if let entryProtocol = entry.connectionProtocol {
            connectionProtocol = entryProtocol
        }
        
        // Restore target auth method from history when Tab accepts a suggestion
        switch entry.authType {
        case .password, .savedPassword:
            authMethod = .password
            password = "" // Will check for saved password below
        case .key(_, _):
            // Use enhanced resolution with hints instead of simple findKey
            if let resolvedKey = ConnectionKeyResolver.resolveFromHistory(
                authType: entry.authType,
                hints: entry.keyResolutionHints,
                connectionIdentity: entry.connectionIdentity
            ) {
                authMethod = .key
                selectedKeyID = resolvedKey.id
            } else {
                // Key unresolvable — keep key auth but show warning via nil selectedKeyID
                authMethod = .key
                selectedKeyID = nil
            }
        case .keyboardInteractive:
            authMethod = .keyboardInteractive
        case .none:
            authMethod = .none  // Tailscale/WireGuard pre-authenticated
        case .unknown:
            authMethod = .none  // Newer app's auth type; shown as None
        }

        // Always check for a saved password, regardless of recorded auth type
        if authMethod == .password {
            Task {
                do {
                    let savedPassword = try await SSHPasswordManager.shared.loadPassword(
                        host: entry.host,
                        port: entry.port,
                        username: entry.username
                    )
                    password = savedPassword
                } catch {
                    // No saved password or load failed - leave empty for user to enter
                }
            }
        }
        
        // Restore jump host settings if present
        if entry.hasJumpHost {
            useJumpHost = true
            jumpHostname = entry.jumpHost ?? ""
            jumpPort = "\(entry.jumpPort ?? 22)"
            jumpUsername = entry.jumpUsername ?? ""
            
            // Restore jump host auth method
            if let jumpAuth = entry.jumpAuthType {
                switch jumpAuth {
                case .password, .savedPassword:
                    jumpAuthMethod = .password
                    jumpPassword = "" // Will check for saved password below
                case .key(_, _):
                    // Use enhanced resolution with hints
                    if let resolvedKey = ConnectionKeyResolver.resolveJumpHostFromHistory(
                        jumpAuthType: jumpAuth,
                        hints: entry.keyResolutionHints,
                        connectionIdentity: entry.connectionIdentity
                    ) {
                        jumpAuthMethod = .key
                        jumpSelectedKeyID = resolvedKey.id
                    } else {
                        jumpAuthMethod = .key
                        jumpSelectedKeyID = nil
                    }
                case .keyboardInteractive:
                    jumpAuthMethod = .keyboardInteractive
                case .none:
                    jumpAuthMethod = .none  // Tailscale/WireGuard pre-authenticated
                case .unknown:
                    jumpAuthMethod = .none  // Newer app's auth type; shown as None
                }
            }

            // Always check for a saved jump host password
            if jumpAuthMethod == .password {
                let jumpHost = entry.jumpHost ?? ""
                let jumpPortNum = entry.jumpPort ?? 22
                let jumpUser = entry.jumpUsername ?? ""
                Task {
                    do {
                        let savedPassword = try await SSHPasswordManager.shared.loadPassword(
                            host: jumpHost,
                            port: jumpPortNum,
                            username: jumpUser
                        )
                        self.jumpPassword = savedPassword
                    } catch {
                        // No saved password or load failed - leave empty for user to enter
                    }
                }
            }
        }
        
        // Restore agent forwarding settings if present
        if let agentConfig = entry.agentConfig {
            enableAgentForwarding = agentConfig.enabled
            agentApprovalMode = agentConfig.approvalMode
            // Empty forwardedKeyIDs means "forward all keys"
            agentForwardAllKeys = agentConfig.forwardedKeyIDs.isEmpty
            agentSelectedKeyIDs = agentConfig.forwardedKeyIDs
        }

        // Restore GPG agent forwarding settings from the selected
        // entry. The else branch is load-bearing: if the user
        // previously selected a GPG-enabled entry and then picks a
        // legacy/disabled one, we must reset the form state so the
        // stale GPG selection doesn't leak into the next connection.
        if let gpg = entry.gpgAgentConfig {
            enableGPGAgentForwarding = gpg.enabled
            gpgAgentApprovalMode = gpg.approvalMode
            gpgForwardAllKeys = gpg.forwardedKeyIDs.isEmpty
            gpgSelectedKeyIDs = gpg.forwardedKeyIDs
            gpgRemoteSocketPath = gpg.remoteSocketPath
        } else {
            enableGPGAgentForwarding = false
            gpgAgentApprovalMode = .perRequest
            gpgForwardAllKeys = true
            gpgSelectedKeyIDs = []
            gpgRemoteSocketPath = GPGAgentConfig.defaultRemoteSocketPath
        }

        // Restore port forwarding settings if present
        if let portForwardConfig = entry.portForwardConfig {
            portForwards = portForwardConfig.forwards
        }
        
        // Restore multiplexer settings if present
        enableTmux = entry.tmuxAutoEnable ?? false
        tmuxAutoMode = entry.tmuxAutoMode ?? .regular
        enableHerdr = entry.herdrAutoEnable ?? false
        enableZmx = entry.zmxAutoEnable ?? false

        // Restore launch command if present
        launchCommand = entry.launchCommand ?? ""
        launchCommandMode = entry.launchCommandMode ?? .afterConnect

        // Restore the carried overrides if present
        restoreCarriedOverrides(terminalType: entry.terminalType,
                                multiplexerSessionName: entry.multiplexerSessionName,
                                host: entry.host,
                                username: entry.username,
                                port: entry.port)
    }
    
    private func handleProfileAccepted(_ profile: ConnectionProfile) {
        quickConnectProfile = profile
        let config = profile.sshConfig
        
        // Set protocol from profile
        connectionProtocol = profile.connectionProtocol
        
        // Set basic connection fields
        quickConnectText = config.port == 22
        ? "\(config.username)@\(config.host)"
        : "\(config.username)@\(config.host):\(config.port)"
        
        // Set auth method
        switch config.authMethod {
        case .password, .savedPassword:
            authMethod = .password
            password = "" // Will check for saved password below
        case .key(let keyID):
            if sshKeyManager.findKey(id: keyID) != nil {
                authMethod = .key
                selectedKeyID = keyID
            } else {
                authMethod = .password
            }
        case .keyboardInteractive:
            authMethod = .keyboardInteractive
        case .none:
            authMethod = .none  // Tailscale/WireGuard pre-authenticated
        case .unknown:
            authMethod = .none  // Newer app's auth type; shown as None
        }

        // Always check for a saved password, regardless of recorded auth type
        if authMethod == .password {
            let host = config.host
            let port = config.port
            let username = config.username
            Task {
                do {
                    let savedPassword = try await SSHPasswordManager.shared.loadPassword(
                        host: host,
                        port: port,
                        username: username
                    )
                    password = savedPassword
                } catch {
                    // No saved password or load failed - leave empty for user to enter
                }
            }
        }
        
        // Set jump host settings if present
        if let jumpConfig = config.jumpHost {
            useJumpHost = true
            jumpHostname = jumpConfig.host
            jumpPort = "\(jumpConfig.port)"
            jumpUsername = jumpConfig.username
            
            switch jumpConfig.authMethod {
            case .password, .savedPassword:
                jumpAuthMethod = .password
                jumpPassword = "" // Will check for saved password below
            case .key(let keyID):
                if sshKeyManager.findKey(id: keyID) != nil {
                    jumpAuthMethod = .key
                    jumpSelectedKeyID = keyID
                } else {
                    jumpAuthMethod = .password
                }
            case .keyboardInteractive:
                jumpAuthMethod = .keyboardInteractive
            case .none:
                jumpAuthMethod = .none  // Tailscale/WireGuard pre-authenticated
            case .unknown:
                jumpAuthMethod = .none  // Newer app's auth type; shown as None
            }

            // Always check for a saved jump host password
            if jumpAuthMethod == .password {
                let jumpHost = jumpConfig.host
                let jumpPortNum = jumpConfig.port
                let jumpUser = jumpConfig.username
                Task {
                    do {
                        let savedPassword = try await SSHPasswordManager.shared.loadPassword(
                            host: jumpHost,
                            port: jumpPortNum,
                            username: jumpUser
                        )
                        self.jumpPassword = savedPassword
                    } catch {
                        // No saved password or load failed - leave empty for user to enter
                    }
                }
            }
        } else {
            useJumpHost = false
        }
        
        // Set agent forwarding settings
        enableAgentForwarding = config.agentConfig.enabled
        agentApprovalMode = config.agentConfig.approvalMode
        agentForwardAllKeys = config.agentConfig.forwardedKeyIDs.isEmpty
        agentSelectedKeyIDs = config.agentConfig.forwardedKeyIDs

        // Set GPG agent forwarding settings
        enableGPGAgentForwarding = config.gpgAgentConfig.enabled
        gpgAgentApprovalMode = config.gpgAgentConfig.approvalMode
        gpgForwardAllKeys = config.gpgAgentConfig.forwardedKeyIDs.isEmpty
        gpgSelectedKeyIDs = config.gpgAgentConfig.forwardedKeyIDs
        gpgRemoteSocketPath = config.gpgAgentConfig.remoteSocketPath

        // Set port forwarding settings
        portForwards = config.portForwardConfig.forwards
        
        // Set multiplexer settings
        enableTmux = config.tmuxAutoEnable
        tmuxAutoMode = config.tmuxAutoMode
        enableHerdr = config.herdrAutoEnable
        enableZmx = config.zmxAutoEnable

        // Set launch command
        launchCommand = config.launchCommand ?? ""
        launchCommandMode = config.launchCommandMode

        // Set the carried overrides
        restoreCarriedOverrides(terminalType: config.terminalType,
                                multiplexerSessionName: config.multiplexerSessionName,
                                host: config.host,
                                username: config.username,
                                port: config.port)

    }
    
    /// Handle unified suggestion acceptance (history or cloud instance)
    private func handleUnifiedSuggestionAccepted(_ suggestion: AnyQuickConnectSuggestion) {
        quickConnectProfile = nil
        // Defer setting suggestion detail and cloud label until after SwiftUI's update cycle
        // processes the text change. This prevents updateFieldsFromQuickConnect (triggered by
        // .onChange) from immediately clearing these values after we set them.
        Task { @MainActor in
            // Update detail text display
            selectedSuggestionDetail = suggestion.detailText
            
            switch suggestion.sourceType {
            case .history:
                // Clear cloud instance label for history entries
                selectedCloudInstanceLabel = nil
                // Find the original history entry and restore auth settings
                if let entry = historyManager.entries.first(where: { $0.id == suggestion.id }) {
                    handleSuggestionAccepted(entry)
                }
                
            case .cloudInstance:
                // Store the cloud instance label for use in tab name
                // displayString is the VM label (e.g., "gpu1")
                selectedCloudInstanceLabel = suggestion.displayString
                
                // Try to find a matching history entry for this cloud instance's host
                // to restore saved auth settings (key, agent forwarding, jump host, etc.)
                let parsed = QuickConnectParser.parse(suggestion.completionString)
                if let host = parsed.host {
                    // Look for history entries with the same host (IP address)
                    // entries is sorted by lastUsed descending, so first match is most recent
                    // Prefer entries with connectionProtocol set (newer format) over legacy nil entries
                    let matchingEntries = historyManager.entries.filter { $0.host == host }
                    let matchingEntry = matchingEntries.first(where: { $0.connectionProtocol != nil })
                    ?? matchingEntries.first
                    if let matchingEntry {
                        handleSuggestionAccepted(matchingEntry)
                        return
                    }
                }
                
                // No matching history - fall back to default key if available
                if selectedKeyID != nil {
                    authMethod = .key
                }
                
            case .localNetwork:
                // Clear cloud instance label for local network entries
                selectedCloudInstanceLabel = nil

                // Discovered Screen Sharing hosts complete to vnc:// — the
                // text change already populated the VNC form; SSH history
                // restoration doesn't apply.
                if Self.parseVNCQuickConnect(suggestion.completionString) != nil {
                    return
                }

                // Local network suggestions may have a matched history entry embedded
                // Try to find matching history by hostname to restore auth settings
                let parsed = QuickConnectParser.parse(suggestion.completionString)
                if let host = parsed.host {
                    // Look for history entries with the same host (hostname or IP)
                    // entries is sorted by lastUsed descending, so first match is most recent
                    // Prefer entries with connectionProtocol set (newer format) over legacy nil entries
                    let hostLower = host.lowercased()
                    let hostWithoutLocal = hostLower.replacingOccurrences(of: ".local", with: "")
                    
                    let matchingEntries = historyManager.entries.filter {
                        $0.host.lowercased() == hostLower ||
                        $0.host.lowercased() == hostWithoutLocal
                    }
                    let matchingEntry = matchingEntries.first(where: { $0.connectionProtocol != nil })
                    ?? matchingEntries.first
                    if let matchingEntry {
                        handleSuggestionAccepted(matchingEntry)
                        return
                    }
                }
                
                // No matching history - fall back to default key if available
                if selectedKeyID != nil {
                    authMethod = .key
                }
                
            case .profile:
                // Clear cloud instance label for profile entries
                selectedCloudInstanceLabel = nil

                // Find the profile and apply its config (VNC profiles switch
                // to the Screen Sharing form instead of the SSH fields)
                if let profile = ConnectionProfileManager.shared.profiles.first(where: { $0.id == suggestion.id }) {
                    if profile.connectionProtocol == .local {
                        guard profile.isAvailableOnCurrentPlatform else { return }
                        onProfileConnect?(profile, splitOption)
                        close()
                    } else if profile.connectionProtocol == .vnc {
                        applyVNCProfile(profile)
                    } else {
                        handleProfileAccepted(profile)
                    }
                }
            }
        }
    }
    
    /// Apply selection from the host browse sheet
    private func applyBrowseSelection(_ selection: BrowseHostSelection) {
        quickConnectProfile = nil
        // Discovered Screen Sharing hosts go straight to the VNC form; the
        // SSH auth/username restoration below doesn't apply to them.
        if selection.serviceKind == .vnc {
            applyVNCTarget(hostname: selection.hostname, port: selection.port)
            return
        }

        // Switch to SSH mode to show the populated form
        connectionType = .ssh
        
        // Populate basic fields
        hostname = selection.hostname
        if let user = selection.username {
            username = user
        }
        if let p = selection.port {
            port = "\(p)"
        } else {
            port = "22"
        }
        
        // Build and set quick connect string
        var quickConnect = ""
        if let user = selection.username, !user.isEmpty {
            quickConnect = "\(user)@\(selection.hostname)"
        } else {
            quickConnect = selection.hostname
        }
        if let p = selection.port, p != 22 {
            quickConnect += ":\(p)"
        }
        quickConnectText = quickConnect
        
        // Clear HSS tracking since this is a direct selection
        currentHSSShorthand = nil
        
        // Clear suggestion detail
        selectedSuggestionDetail = nil

        // Deferred until after SwiftUI's update cycle runs
        // .onChange(of: quickConnectText) -> updateFieldsFromQuickConnect, which
        // clears the label for the previous destination. Setting it
        // synchronously means that clear lands last and wins, so a browse
        // selection lost its cloud instance label. Same reasoning, and same
        // shape, as handleUnifiedSuggestionAccepted. (The carried overrides
        // don't depend on this ordering — dropCarriedOverridesIfNotFor keys off
        // the destination identity.)
        Task { @MainActor in
            // Set cloud instance label for tab naming
            selectedCloudInstanceLabel = selection.cloudInstanceLabel

            // Handle auth restoration from history (this also restores the
            // connection's TERM override)
            if let entry = selection.historyEntry {
                handleSuggestionAccepted(entry)
            } else if let defaultKeyID = sshKeyManager.primaryDefaultKeyID,
                      sshKeyManager.findKey(id: defaultKeyID) != nil {
                // No history match - fall back to primary default key if available
                authMethod = .key
                selectedKeyID = defaultKeyID
            }
        }
    }
    
}

// MARK: - Kubernetes Extension

extension SSHConnectionView {
    /// Filtered nodes based on search query
    private var filteredNodes: [ClusterNodeInfo] {
        guard !nodeSearchQuery.isEmpty else { return nodes }
        return nodes.filter { $0.matches(searchQuery: nodeSearchQuery) }
    }
    
    /// Nodes grouped by node pool
    private var nodesByPool: [(pool: String, nodes: [ClusterNodeInfo])] {
        let grouped = Dictionary(grouping: filteredNodes) { node in
            node.nodePool ?? "default"
        }
        return grouped.sorted { $0.key < $1.key }.map { (pool: $0.key, nodes: $0.value) }
    }
    
    /// Whether nodes have multiple pools (to decide if grouping is useful)
    private var hasMultiplePools: Bool {
        Set(nodes.compactMap { $0.nodePool }).count > 1
    }
    
    /// Kubernetes connection view
    @ViewBuilder
    var kubernetesConnectionView: some View {
        VStack(spacing: 0) {
            compactOpenAsHeader
            
            Form {
                // Cluster Selection
                Section("Cluster") {
                    Group {
                        if clusterManager.clusters.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundColor(.secondary)
                                    Text("No clusters imported")
                                        .foregroundColor(.secondary)
                                }
                                
                                NavigationLink(destination: KubernetesClusterImportView()) {
                                    Label("Import Kubeconfig", systemImage: "plus.circle")
                                }
                            }
                        } else {
                            Picker("Select Cluster", selection: $selectedCluster) {
                                Text("Select...").tag(nil as KubernetesCluster?)
                                ForEach(clusterManager.clusters) { cluster in
                                    Text(cluster.label).tag(cluster as KubernetesCluster?)
                                }
                            }
                        }
                    }
                    .themedRow()
                }
                
                // Node Selection (only if cluster selected)
                if selectedCluster != nil {
                    if isLoadingNodes {
                        Section("Node") {
                            Group {
                                HStack {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Loading nodes...")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .themedRow()
                        }
                    } else if nodes.isEmpty {
                        Section("Node") {
                            Group {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                    Text("No nodes available")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .themedRow()
                        }
                    } else {
                        // Search field (only show for larger clusters)
                        if nodes.count > 5 {
                            Section {
                                Group {
                                    HStack {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(.secondary)
                                        TextField("Search by name, IP, or label...", text: $nodeSearchQuery)
                                            .autocapitalization(.none)
                                            .autocorrectionDisabled()
                                        if !nodeSearchQuery.isEmpty {
                                            Button(action: { nodeSearchQuery = "" }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .themedRow()
                            }
                        }
                        
                        // Node list - grouped by pool if multiple pools exist
                        if hasMultiplePools {
                            ForEach(nodesByPool, id: \.pool) { poolGroup in
                                Section(header: Text(poolGroup.pool).textCase(nil)) {
                                    Group {
                                        ForEach(poolGroup.nodes) { node in
                                            NodeSelectionRow(
                                                node: node,
                                                isSelected: selectedNode?.id == node.id,
                                                onSelect: { selectedNode = node }
                                            )
                                        }
                                    }
                                    .themedRow()
                                }
                            }
                        } else {
                            Section("Node (\(filteredNodes.count))") {
                                Group {
                                    ForEach(filteredNodes) { node in
                                        NodeSelectionRow(
                                            node: node,
                                            isSelected: selectedNode?.id == node.id,
                                            onSelect: { selectedNode = node }
                                        )
                                    }
                                }
                                .themedRow()
                            }
                        }
                        
                        // No results message
                        if !nodeSearchQuery.isEmpty && filteredNodes.isEmpty {
                            Section {
                                Group {
                                    HStack {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(.secondary)
                                        Text("No nodes match '\(nodeSearchQuery)'")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .themedRow()
                            }
                        }
                        
                        // Selected node warning
                        if let node = selectedNode, !node.isReady {
                            Section {
                                Group {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundColor(.orange)
                                        Text("Selected node is not ready")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                                .themedRow()
                            }
                        }
                    }
                }
                
                // Pod Type Selection (only if cluster and node selected)
                if selectedCluster != nil && selectedNode != nil {
                    Section {
                        Group {
                            Picker("Pod Type", selection: $selectedPodType) {
                                ForEach(KubernetesDebugPodType.allCases, id: \.self) { podType in
                                    HStack {
                                        Image(systemName: podType.iconName)
                                        VStack(alignment: .leading) {
                                            Text(podType.displayName)
                                            Text(podType.description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .tag(podType)
                                }
                            }
                            .pickerStyle(.inline)
                        }
                        .themedRow()
                    } header: {
                        Text("Pod Type")
                    } footer: {
                        if selectedPodType == .containerShell {
                            Text("Container Shell runs /bin/sh directly in the debug pod. Host filesystem is accessible at /host.")
                                .font(.caption)
                        }
                    }
                }
                
                // Error display
                if let error = errorMessage {
                    Section {
                        Group {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
#if !os(visionOS)
            .scrollDismissesKeyboard(.immediately)
#endif
            .onChange(of: selectedCluster) { _, cluster in
                nodeSearchQuery = "" // Clear search when changing clusters
                if let cluster = cluster {
                    loadNodes(for: cluster)
                } else {
                    nodes = []
                    selectedNode = nil
                }
            }
            .onAppear {
                if selectedCluster == nil && clusterManager.clusters.count == 1 {
                    // Auto-select the cluster if there's only one available
                    selectedCluster = clusterManager.clusters.first
                } else if let cluster = selectedCluster, nodes.isEmpty && !isLoadingNodes {
                    // Cluster was already selected (from connectionType onChange), but nodes weren't loaded
                    loadNodes(for: cluster)
                }
            }
        }
    }
}

// MARK: - Node Selection Row

/// A row for selecting a node in the Kubernetes connection view
private struct NodeSelectionRow: View {
    let node: ClusterNodeInfo
    let isSelected: Bool
    let onSelect: () -> Void
    
    /// Formatted IP display string
    private var ipDisplayText: String? {
        switch (node.internalIP, node.externalIP) {
        case (let intIP?, let extIP?):
            // Both IPs available
            return "\(intIP) (int) · \(extIP) (ext)"
        case (let intIP?, nil):
            // Only internal IP
            return intIP
        case (nil, let extIP?):
            // Only external IP
            return "\(extIP) (ext)"
        case (nil, nil):
            return nil
        }
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                // Status indicator
                Image(systemName: node.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundColor(node.isReady ? .green : .orange)
                    .font(.body)
                
                // Node info
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    if let ipText = ipDisplayText {
                        Text(ipText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Kubernetes Private Methods

extension SSHConnectionView {
    /// Load nodes for a cluster
    func loadNodes(for cluster: KubernetesCluster) {
        isLoadingNodes = true
        nodes = []
        selectedNode = nil
        errorMessage = nil
        
        Task {
            do {
                let fetchedNodes = try await clusterManager.getClusterNodes(cluster)
                nodes = fetchedNodes.sorted { $0.name < $1.name }
                
                // Auto-select the first ready node for faster selection
                if selectedNode == nil, let firstReadyNode = nodes.first(where: { $0.isReady }) {
                    selectedNode = firstReadyNode
                } else if selectedNode == nil, let firstNode = nodes.first {
                    // Fall back to first node even if not ready (user can see the warning)
                    selectedNode = firstNode
                }
                
                isLoadingNodes = false
            } catch {
                errorMessage = "Failed to load nodes: \(error.localizedDescription)"
                isLoadingNodes = false
            }
        }
    }
    
    /// Connect to Kubernetes node
    func connectKubernetes() {
        guard let cluster = selectedCluster,
              let node = selectedNode else {
            errorMessage = "Please select a cluster and node"
            return
        }
        
        guard node.isReady else {
            errorMessage = "Selected node is not ready"
            return
        }
        
        isConnecting = true
        errorMessage = nil
        
        // Create config
        let config = KubernetesNodeShellConfig(
            clusterId: cluster.id,
            nodeName: node.name,
            podType: selectedPodType
        )
        
        // Call the Kubernetes callback
        onKubernetesConnect?(config, splitOption)
        dismiss()
    }
}

// MARK: - Console Extension

extension SSHConnectionView {
    /// Whether all accounts are effectively selected (empty set = all)
    private var isAllAccountsSelected: Bool {
        selectedConsoleAccountIDs.isEmpty ||
        selectedConsoleAccountIDs.count == consoleCapableAccounts.count
    }
    
    /// Accounts to include in search
    private var effectiveAccountIDs: Set<UUID> {
        selectedConsoleAccountIDs.isEmpty
        ? Set(consoleCapableAccounts.map { $0.id })
        : selectedConsoleAccountIDs
    }
    
    /// Filtered and grouped console instances by account
    private var filteredConsoleInstancesByAccount: [(account: CloudAccount, instances: [CloudInstance])] {
        var results: [(account: CloudAccount, instances: [CloudInstance])] = []
        
        for account in consoleCapableAccounts where effectiveAccountIDs.contains(account.id) {
            let accountInstances = allConsoleInstances.filter { $0.accountID == account.id }
            let filtered = consoleInstanceSearchQuery.isEmpty
            ? accountInstances
            : accountInstances.filter { $0.matches(query: consoleInstanceSearchQuery) }
            
            if !filtered.isEmpty {
                results.append((account: account, instances: filtered.sorted { $0.label < $1.label }))
            }
        }
        
        // Sort by provider, then account label
        return results.sorted {
            if $0.account.providerID != $1.account.providerID {
                return $0.account.providerID < $1.account.providerID
            }
            return $0.account.label < $1.account.label
        }
    }
    
    /// Total count of filtered instances across all accounts
    private var totalFilteredInstanceCount: Int {
        filteredConsoleInstancesByAccount.reduce(0) { $0 + $1.instances.count }
    }
    
    /// Whether any account is currently syncing (background refresh is transparent)
    private var isLoadingAnyConsoleAccount: Bool {
        false
    }
    
    /// Whether any console instances exist across all accounts
    private var hasAnyConsoleInstances: Bool {
        !allConsoleInstances.isEmpty
    }
    
    /// Console connection view
    @ViewBuilder
    var consoleConnectionView: some View {
        VStack(spacing: 0) {
            compactOpenAsHeader
            
            Form {
                // Universal search with filter
                if consoleCapableAccounts.isEmpty {
                    // Empty state - no console-capable accounts
                    Section {
                        Group {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "cloud")
                                        .foregroundColor(.secondary)
                                    Text("No console-capable accounts")
                                        .foregroundColor(.secondary)
                                }
                                
                                NavigationLink(destination: CloudAccountAddView()) {
                                    Label("Add Cloud Account", systemImage: "plus.circle")
                                }
                            }
                        }
                        .themedRow()
                    }
                } else {
                    // Search bar with filter button
                    Section {
                        Group {
                            consoleSearchBar
                            
                            if !isAllAccountsSelected {
                                consoleActiveFilterChips
                            }
                        }
                        .themedRow()
                    }
                    
                    // Loading state for initial sync
                    if isLoadingAnyConsoleAccount && !hasLoadedConsoleInstances {
                        Section {
                            Group {
                                HStack {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Loading instances...")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .themedRow()
                        }
                    } else if filteredConsoleInstancesByAccount.isEmpty && !consoleInstanceSearchQuery.isEmpty {
                        // No search results
                        Section {
                            Group {
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                    Text("No instances match '\(consoleInstanceSearchQuery)'")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .themedRow()
                        }
                    } else if filteredConsoleInstancesByAccount.isEmpty && hasLoadedConsoleInstances && !hasAnyConsoleInstances {
                        // No instances at all
                        Section {
                            Group {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                    Text("No instances found in selected accounts")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .themedRow()
                        }
                    } else {
                        // Grouped results by account
                        ForEach(filteredConsoleInstancesByAccount, id: \.account.id) { group in
                            Section(header: consoleAccountSectionHeader(for: group.account, instanceCount: group.instances.count)) {
                                Group {
                                    ForEach(group.instances) { instance in
                                        ConsoleInstanceRow(
                                            instance: instance,
                                            onConnect: { connectToInstance(instance) }
                                        )
                                    }
                                }
                                .themedRow()
                            }
                        }
                    }
                    
                    // Total count footer
                    if totalFilteredInstanceCount > 0 && !isLoadingAnyConsoleAccount {
                        Section {
                            Group {
                                Text("\(totalFilteredInstanceCount) instance\(totalFilteredInstanceCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .themedRow()
                        }
                    }
                    
                }
                
                // Error display
                if let error = errorMessage {
                    Section {
                        Group {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
#if !os(visionOS)
            .scrollDismissesKeyboard(.immediately)
#endif
            .onAppear {
                loadAllConsoleInstances()
            }
        }
    }
    
    // MARK: - Console Search Bar
    
    private var consoleSearchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search all instances...", text: $consoleInstanceSearchQuery)
                .autocapitalization(.none)
                .autocorrectionDisabled()
            
            if !consoleInstanceSearchQuery.isEmpty {
                Button(action: { consoleInstanceSearchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Filter button with badge
            Button(action: { showAccountFilter = true }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title3)
                    if !isAllAccountsSelected {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }
                }
            }
            .popover(isPresented: $showAccountFilter) {
                AccountFilterPopover(
                    accounts: consoleCapableAccounts,
                    selectedAccountIDs: $selectedConsoleAccountIDs
                )
            }
        }
    }
    
    // MARK: - Active Filter Chips
    
    private var consoleActiveFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(consoleCapableAccounts.filter { selectedConsoleAccountIDs.contains($0.id) }) { account in
                    HStack(spacing: 4) {
                        consoleProviderIcon(for: account.providerID)
                            .frame(width: 14, height: 14)
                        Text(account.label)
                            .font(.caption)
                        Button(action: { removeAccountFromFilter(account.id) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                }
            }
        }
    }
    
    private func removeAccountFromFilter(_ accountID: UUID) {
        selectedConsoleAccountIDs.remove(accountID)
        // If removing last one, show all
        if selectedConsoleAccountIDs.isEmpty {
            // Empty set means all are shown, which is what we want
        }
    }
    
    // MARK: - Provider Section Header
    
    private func consoleAccountSectionHeader(for account: CloudAccount, instanceCount: Int) -> some View {
        HStack(spacing: 8) {
            consoleProviderIcon(for: account.providerID)
                .frame(width: 16, height: 16)
            
            Text(account.label)
                .textCase(nil)
            
            Spacer()
            
            Text("\(instanceCount)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private func consoleProviderIcon(for providerID: String) -> some View {
        switch providerID {
        case LinodeProvider.providerID:
            if let logoName = LinodeProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: LinodeProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        case DigitalOceanProvider.providerID:
            if let logoName = DigitalOceanProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: DigitalOceanProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        case AWSProvider.providerID:
            if let logoName = AWSProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: AWSProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        default:
            Image(systemName: "cloud")
                .foregroundColor(.accentColor)
        }
    }
    
    // MARK: - Data Loading
    
    /// Load instances from all console-capable accounts
    /// Shows cached data immediately, refreshes in background only if cache is stale (> 1 hour)
    func loadAllConsoleInstances() {
        let accountsToLoad = consoleCapableAccounts
        guard !accountsToLoad.isEmpty else { return }
        
        // Immediately populate from cache
        var cachedInstances: [CloudInstance] = []
        for account in accountsToLoad {
            cachedInstances.append(contentsOf: CloudCacheManager.shared.instances(for: account.id))
        }
        
        allConsoleInstances = cachedInstances.sorted { $0.label < $1.label }
        hasLoadedConsoleInstances = true
        errorMessage = nil
        
        // Trigger background refresh only if cache is stale (> 1 hour)
        CloudCacheManager.shared.refreshIfStale()
    }
    
    /// Connect directly to a specific instance
    func connectToInstance(_ instance: CloudInstance) {
        // Get account from instance's accountID
        guard let account = cloudAccountManager.account(for: instance.accountID) else {
            errorMessage = "Account not found for selected instance"
            return
        }
        
        isConnecting = true
        errorMessage = nil
        
        // Route based on provider type
        if account.providerID == "aws" {
            // EC2 Serial Console (SSH-based)
            let config = EC2ConsoleConfig(
                accountId: account.id,
                instanceId: instance.providerInstanceID,
                region: instance.region ?? "us-east-1",
                instanceLabel: instance.label
            )
            onEC2ConsoleConnect?(config, splitOption)
        } else {
            // Linode LISH (WebSocket-based)
            let config = ConsoleConfig(
                accountId: account.id,
                providerInstanceId: instance.providerInstanceID,
                providerID: account.providerID,
                instanceLabel: instance.label
            )
            onConsoleConnect?(config, splitOption)
        }
        dismiss()
    }
    // MARK: - Console Instance Row
    
    /// A row for connecting to an instance in the Console view
    private struct ConsoleInstanceRow: View {
        let instance: CloudInstance
        let onConnect: () -> Void
        
        private var statusColor: Color {
            switch instance.status {
            case .running: return .green
            case .stopped: return .gray
            case .provisioning, .rebooting, .migrating: return .orange
            case .unknown: return .secondary
            }
        }
        
        var body: some View {
            Button(action: onConnect) {
                HStack {
                    // Status indicator
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    
                    // Instance info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instance.label)
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 4) {
                            if let ip = instance.ipv4Address {
                                Text(ip)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let region = instance.region {
                                Text("·")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(region)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            NetworkDeviceInlineBadges(instance: instance)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // Status text
                    Text(instance.status.displayName)
                        .font(.caption)
                        .foregroundColor(instance.status == .running ? .green : .secondary)
                    
                    // Chevron to indicate tappable
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Inline Profiles View
    
    /// Inline profile browser for the connection type menu
    struct InlineProfilesView: View {
        @Environment(\.sheetThemeColors) private var sheetThemeColors
        
        // Manager
        private var profileManager: ConnectionProfileManager { ConnectionProfileManager.shared }
        private var availableTags: [ProfileTag] {
            profileManager.tags(showAllPlatforms: showAllPlatforms)
        }
        
        // Split option binding from parent
        @Binding var splitOption: SSHConnectionView.SplitOption
        
        // State
        @State private var searchQuery: String = ""
        @State private var selectedTags: Set<String> = []
        @State private var showAllPlatforms = false
        @State private var showTagFilter: Bool = false
        @State private var showingNewProfileSheet: Bool = false
        @State private var editingProfile: ConnectionProfile?
        @State private var profileToDelete: ConnectionProfile?
        @State private var newProfileFolder: String = ""
        @Setting(Settings.Connections.profilesSortOrder) private var sortOrder

        // Navigation path for folder browsing
        @Binding var navigationPath: [SSHConnectionView.InlineProfilesRoute]
        
        // Focus state for search field
        @State private var isSearchFocused: Bool = false
        
        // Keyboard navigation
        @State private var highlightedIndex: Int = 0
        @State private var scrollTargetID: String?
        @State private var searchFocusRequestID: Int = 0
        @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()
        @State private var pendingFocusTask: Task<Void, Never>?
        
        let onProfileSelected: (ConnectionProfile, SSHConnectionView.SplitOption) -> Void
        var onCancel: (() -> Void)? = nil
        
        private var currentFolder: String {
            navigationPath.last?.folderPath ?? ""
        }

        // MARK: - Navigable Items
        
        private enum NavigableItem: Identifiable {
            case folder(ProfileFolder)
            case profile(ConnectionProfile)
            
            var id: String {
                switch self {
                case .folder(let f): return "folder:\(f.id)"
                case .profile(let p): return "profile:\(p.id.uuidString)"
                }
            }
        }
        
        private func navigableItems(in folder: String) -> [NavigableItem] {
            var items: [NavigableItem] = []
            if searchQuery.isEmpty && selectedTags.isEmpty {
                items.append(contentsOf: filteredFolders(in: folder).map { .folder($0) })
            }
            items.append(contentsOf: filteredProfiles(in: folder).map { .profile($0) })
            return items
        }
        
        private func isItemHighlighted(_ item: NavigableItem, in folder: String) -> Bool {
            guard KeyboardTracker.shared.isHardwareKeyboard else { return false }
            let items = navigableItems(in: folder)
            guard highlightedIndex < items.count else { return false }
            return items[highlightedIndex].id == item.id
        }
        
        var body: some View {
            profileListView(folder: "")
                .navigationDestination(for: SSHConnectionView.InlineProfilesRoute.self) { route in
                    switch route {
                    case .folder(let folder):
                        profileListView(folder: folder)
                    }
                }
                .onAppear {
                    scheduleSearchFocus(for: currentFolder)
                }
                .onDisappear {
                    arrowKeyRepeatManager.stop()
                    pendingFocusTask?.cancel()
                    pendingFocusTask = nil
                }
                .onChange(of: navigationPath) { _, _ in
                    arrowKeyRepeatManager.stop()
                    pendingFocusTask?.cancel()
                    pendingFocusTask = nil
                    highlightedIndex = 0
                    scrollTargetID = nil
                    isSearchFocused = false
                    scheduleSearchFocus(for: currentFolder)
                }
                .onChange(of: searchQuery) { _, _ in
                    highlightedIndex = 0
                }
                .onChange(of: selectedTags) { _, _ in
                    highlightedIndex = 0
                }
                .onChange(of: Set(availableTags.map(\.name))) { _, names in
                    selectedTags.formIntersection(names)
                    if names.isEmpty { showTagFilter = false }
                }
                .onChange(of: profileManager.hasUnavailableProfiles) { _, hasUnavailable in
                    if !hasUnavailable { showAllPlatforms = false }
                }
                .onChange(of: showAllPlatforms) { _, _ in
                    highlightedIndex = 0
                }
                .onChange(of: sortOrder) { _, _ in
                    highlightedIndex = 0
                }
                .navigationDestination(isPresented: $showingNewProfileSheet) {
                    ProfileEditorSheet(folderPath: currentFolder, embedded: true)
                }
                .navigationDestination(item: $editingProfile) { profile in
                    ProfileEditorSheet(profile: profile, embedded: true)
                }
                .toolbar {
                    if profileManager.hasUnavailableProfiles {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Toggle("Show All Platforms", isOn: $showAllPlatforms)
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                            }
                            .accessibilityLabel("Platform Filter")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            presentNewProfileSheet(in: currentFolder)
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
        }
        
        // MARK: - Profile List View
        
        @ViewBuilder
        private func profileListView(folder: String) -> some View {
            ScrollViewReader { scrollProxy in
                List {
                    // Search section at top
                    searchSection(in: folder)
                    
                    // Folders in current location
                    foldersSection(in: folder)
                    
                    // Profiles in current location
                    profilesSection(in: folder)
                    
                    // No results message
                    noResultsSection(in: folder)
                }
                .themedList()
                .onChange(of: scrollTargetID) { _, target in
                    guard folder == currentFolder, let target else { return }
                    scrollProxy.scrollTo(target, anchor: .center)
                }
            }
            .confirmationDialog(
                "Delete Profile",
                isPresented: Binding(
                    get: { currentFolder == folder && profileToDelete != nil },
                    set: { if !$0 { profileToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: profileToDelete
            ) { profile in
                Button("Delete", role: .destructive) {
                    deleteProfile(profile)
                    profileToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    profileToDelete = nil
                }
            } message: { profile in
                Text("Are you sure you want to delete \"\(profile.name)\"?")
            }
            .listStyle(.insetGrouped)
            .navigationTitle(folder.isEmpty ? "Profiles" : folderName(from: folder))
            .navigationBarTitleDisplayMode(.inline)
            .onKeyPress(.downArrow, phases: .down) { _ in
                moveHighlightDown()
                arrowKeyRepeatManager.start(direction: .down) { [self] in
                    moveHighlightDown()
                }
                return .handled
            }
            .onKeyPress(.downArrow, phases: .up) { _ in
                arrowKeyRepeatManager.stop(direction: .down)
                return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { _ in
                moveHighlightUp()
                arrowKeyRepeatManager.start(direction: .up) { [self] in
                    moveHighlightUp()
                }
                return .handled
            }
            .onKeyPress(.upArrow, phases: .up) { _ in
                arrowKeyRepeatManager.stop(direction: .up)
                return .handled
            }
            .onKeyPress(.return) {
                if isSearchFocused {
                    return .ignored
                }
                arrowKeyRepeatManager.stop()
                if activateHighlightedItem() {
                    return .handled
                }
                return .ignored
            }
            .onDisappear { arrowKeyRepeatManager.stop() }
        }
        
        // MARK: - Search Section
        
        @ViewBuilder
        private func searchSection(in folder: String) -> some View {
            Section {
                Group {
                    searchBar(in: folder)
                    
                    if !selectedTags.isEmpty {
                        activeTagChips
                    }
                }
                .themedRow()
            }
        }
        
        private func searchFocusBinding(for folder: String) -> Binding<Bool> {
            Binding(
                get: { folder == currentFolder && isSearchFocused },
                set: { newValue in
                    guard folder == currentFolder else { return }
                    isSearchFocused = newValue
                }
            )
        }
        
        // MARK: - Search Bar
        
        private func searchBar(in folder: String) -> some View {
            BrowseSearchBar(
                searchQuery: $searchQuery,
                placeholder: String(localized: "Search profiles..."),
                focusedBinding: searchFocusBinding(for: folder),
                focusRequestID: searchFocusRequestID,
                onEscape: { handleEscapeKey() },
                onMoveUp: {
                    moveHighlightUp()
                    arrowKeyRepeatManager.start(direction: .up) { [self] in
                        moveHighlightUp()
                    }
                },
                onMoveDown: {
                    moveHighlightDown()
                    arrowKeyRepeatManager.start(direction: .down) { [self] in
                        moveHighlightDown()
                    }
                },
                onStopMoveUp: { arrowKeyRepeatManager.stop(direction: .up) },
                onStopMoveDown: { arrowKeyRepeatManager.stop(direction: .down) },
                onSubmit: { activateHighlightedItem() }
            ) {
                // Tag filter button (only show if tags exist)
                if !availableTags.isEmpty {
                    Button(action: { showTagFilter = true }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "tag")
                                .font(.title3)
                            if !selectedTags.isEmpty {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                    .popover(isPresented: $showTagFilter, arrowEdge: .top) {
                        TagFilterPopover(
                            tags: availableTags,
                            selectedTags: $selectedTags
                        )
                        .themedSubSheet(sheetThemeColors)
                        .presentationCompactAdaptation(.popover)
                    }
                }

                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(ProfileSortOrder.allCases, id: \.rawValue) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    if SettingPinActions.hasActions(for: Settings.Connections.profilesSortOrder.erased) {
                        Section {
                            SettingPinActions(definition: Settings.Connections.profilesSortOrder.erased)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.title3)
                }
            }
            .id("inline-profiles-search-\(folder.isEmpty ? "root" : folder)")
            .onAppear {
                guard folder == currentFolder else { return }
                scheduleSearchFocus(for: folder)
            }
        }
        
        // MARK: - Active Tag Chips
        
        private var activeTagChips: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(selectedTags), id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.caption)
                            
                            Button {
                                selectedTags.remove(tag)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        
        // MARK: - Folders Section
        
        @ViewBuilder
        private func foldersSection(in folder: String) -> some View {
            let subfolders = filteredFolders(in: folder)
            if !subfolders.isEmpty && searchQuery.isEmpty && selectedTags.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { subfolder in
                        Button {
                            navigateIntoFolder(subfolder.path)
                        } label: {
                            FolderRow(folder: subfolder)
                        }
                        .id("folder:\(subfolder.id)")
                        .listRowBackground(
                            isItemHighlighted(.folder(subfolder), in: folder)
                            ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground
                        )
                    }
                }
            }
        }
        
        // MARK: - Profiles Section
        
        @ViewBuilder
        private func profilesSection(in folder: String) -> some View {
            let profiles = filteredProfiles(in: folder)
            if !profiles.isEmpty {
                Section(searchQuery.isEmpty && selectedTags.isEmpty ? "Profiles" : "Results") {
                    ForEach(profiles) { profile in
                        ProfileRow(profile: profile)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    profileToDelete = profile
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    editingProfile = profile
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                                
                                Button {
                                    duplicateProfile(profile)
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                }
                                .tint(.orange)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectProfile(profile)
                            }
                            .contextMenu {
                                profileContextMenu(profile)
                            }
                            .id("profile:\(profile.id.uuidString)")
                            .listRowBackground(
                                isItemHighlighted(.profile(profile), in: folder)
                                ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground
                            )
                    }
                }
            }
        }
        
        // MARK: - No Results Section
        
        @ViewBuilder
        private func noResultsSection(in folder: String) -> some View {
            let subfolders = filteredFolders(in: folder)
            let profiles = filteredProfiles(in: folder)
            
            if subfolders.isEmpty && profiles.isEmpty {
                Section {
                    Group {
                        if !searchQuery.isEmpty || !selectedTags.isEmpty {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                Text("No profiles match your search")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            HStack {
                                Image(systemName: "star")
                                    .foregroundColor(.secondary)
                                Text("No profiles yet")
                                    .foregroundColor(.secondary)
                            }
                            Button {
                                presentNewProfileSheet(in: folder)
                            } label: {
                                Label("Create Profile", systemImage: "plus")
                            }
                        }
                    }
                    .themedRow()
                }
            }
        }
        
        // MARK: - Context Menu
        
        @ViewBuilder
        private func profileContextMenu(_ profile: ConnectionProfile) -> some View {
            if HostAddressCopyActions.hasActions(
                hostname: profile.sshConfig.host,
                ipAddress: nil
            ) {
                HostAddressCopyActions(hostname: profile.sshConfig.host)
                Divider()
            }

            Button {
                editingProfile = profile
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            
            Button {
                duplicateProfile(profile)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            
            Divider()
            
            Button(role: .destructive) {
                profileToDelete = profile
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        
        // MARK: - Filtering
        
        private func filteredFolders(in parentPath: String) -> [ProfileFolder] {
            profileManager.subfolders(of: parentPath, showAllPlatforms: showAllPlatforms)
        }
        
        private func filteredProfiles(in folder: String) -> [ConnectionProfile] {
            var profiles: [ConnectionProfile]
            
            if !searchQuery.isEmpty {
                // Search across all profiles
                profiles = profileManager.profiles(matching: searchQuery)
            } else if !selectedTags.isEmpty {
                // Filter by tags across all profiles
                profiles = profileManager.profiles.filter { profile in
                    !selectedTags.isDisjoint(with: profile.tags)
                }
            } else {
                // Show profiles in current folder only
                profiles = profileManager.profiles(inFolder: folder)
            }
            
            return profiles.filter { showAllPlatforms || $0.isAvailableOnCurrentPlatform }
                .sorted(by: sortOrder.compare)
        }
        
        // MARK: - Actions
        
        @discardableResult
        private func activateHighlightedItem() -> Bool {
            let items = navigableItems(in: currentFolder)
            guard highlightedIndex < items.count else { return false }
            switch items[highlightedIndex] {
            case .folder(let folder):
                navigateIntoFolder(folder.path)
            case .profile(let profile):
                selectProfile(profile)
            }
            return true
        }
        
        private func selectProfile(_ profile: ConnectionProfile) {
            guard profile.isAvailableOnCurrentPlatform else {
                editingProfile = profile
                return
            }
            onProfileSelected(profile, splitOption)
        }
        
        private func duplicateProfile(_ profile: ConnectionProfile) {
            _ = try? profileManager.duplicateProfile(id: profile.id)
        }
        
        private func deleteProfile(_ profile: ConnectionProfile) {
            _ = try? profileManager.deleteProfile(id: profile.id)
        }
        
        private func presentNewProfileSheet(in folder: String) {
            newProfileFolder = folder
            showingNewProfileSheet = true
        }
        
        private func folderName(from path: String) -> String {
            guard let lastSlash = path.lastIndex(of: "/") else {
                return path
            }
            return String(path[path.index(after: lastSlash)...])
        }
        
        private func handleEscapeKey() {
            if !navigationPath.isEmpty {
                navigateToParentFolder()
                return
            }
            onCancel?()
        }
        
        private func restoreSearchFocus() {
            guard KeyboardTracker.shared.isHardwareKeyboard else {
                isSearchFocused = false
                return
            }
            isSearchFocused = true
            searchFocusRequestID &+= 1
        }
        
        private func scheduleSearchFocus(for folder: String) {
            pendingFocusTask?.cancel()
            pendingFocusTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, currentFolder == folder else { return }
                restoreSearchFocus()
            }
        }
        
        private func moveHighlightDown() {
            let items = navigableItems(in: currentFolder)
            guard !items.isEmpty else { return }
            let lastIndex = items.count - 1
            let current = min(max(highlightedIndex, 0), lastIndex)
            highlightedIndex = min(current + 1, lastIndex)
            scrollTargetID = items[highlightedIndex].id
        }

        private func moveHighlightUp() {
            let items = navigableItems(in: currentFolder)
            guard !items.isEmpty else { return }
            let lastIndex = items.count - 1
            let current = min(max(highlightedIndex, 0), lastIndex)
            highlightedIndex = max(current - 1, 0)
            scrollTargetID = items[highlightedIndex].id
        }
        
        private func navigateIntoFolder(_ path: String) {
            isSearchFocused = false
            navigationPath.append(.folder(path))
        }
        
        private func navigateToParentFolder() {
            guard !navigationPath.isEmpty else { return }
            isSearchFocused = false
            navigationPath.removeLast()
        }
    }
}

#if !os(visionOS)
/// iOS/iPadOS 27-only host. UIKit owns the horizontal scroll recognizer (the
/// part that is regressed), while its stable UIHostingController renders the
/// original SwiftUI Liquid Glass strip pixel-for-pixel.
private struct ConnectionTypeIOS27ScrollHost: UIViewControllerRepresentable {
    let types: [SSHConnectionView.ConnectionType]
    let selection: SSHConnectionView.ConnectionType
    let selectedBackgroundColor: Color
    let accentColor: Color
    let colorScheme: ColorScheme
    let onSelect: (SSHConnectionView.ConnectionType) -> Void

    func makeUIViewController(context: Context) -> ConnectionTypeIOS27ScrollController {
        ConnectionTypeIOS27ScrollController(
            types: types,
            selection: selection,
            selectedBackgroundColor: selectedBackgroundColor,
            accentColor: accentColor,
            colorScheme: colorScheme,
            onSelect: onSelect
        )
    }

    func updateUIViewController(
        _ controller: ConnectionTypeIOS27ScrollController,
        context: Context
    ) {
        controller.update(
            types: types,
            selection: selection,
            selectedBackgroundColor: selectedBackgroundColor,
            accentColor: accentColor,
            colorScheme: colorScheme,
            onSelect: onSelect
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: ConnectionTypeIOS27ScrollController,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiViewController.fittingHeight)
    }
}

@MainActor @Observable
private final class ConnectionTypeIOS27Model {
    var types: [SSHConnectionView.ConnectionType]
    var selection: SSHConnectionView.ConnectionType
    var selectedBackgroundColor: Color
    var accentColor: Color
    var colorScheme: ColorScheme
    @ObservationIgnored var onSelect: (SSHConnectionView.ConnectionType) -> Void

    init(
        types: [SSHConnectionView.ConnectionType],
        selection: SSHConnectionView.ConnectionType,
        selectedBackgroundColor: Color,
        accentColor: Color,
        colorScheme: ColorScheme,
        onSelect: @escaping (SSHConnectionView.ConnectionType) -> Void
    ) {
        self.types = types
        self.selection = selection
        self.selectedBackgroundColor = selectedBackgroundColor
        self.accentColor = accentColor
        self.colorScheme = colorScheme
        self.onSelect = onSelect
    }
}

private struct ConnectionTypeIOS27GlassStrip: View {
    let model: ConnectionTypeIOS27Model
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.types, id: \.self) { type in
                let isSelected = model.selection == type

                Label(type.displayName, systemImage: type.iconName)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .modifier(
                        GlassTabBackgroundModifier(
                            isSelected: isSelected,
                            selectedBackgroundColor: model.selectedBackgroundColor,
                            unselectedBackgroundColor: .clear,
                            id: Self.tabID(for: type),
                            namespace: namespace,
                            isLightTheme: model.colorScheme == .light,
                            isHovered: false
                        )
                    )
                    .foregroundStyle(isSelected ? model.accentColor : Color.primary)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                    .overlay {
                        ConnectionTypeUIKitTapTarget(
                            type: type,
                            isSelected: isSelected,
                            onSelect: model.onSelect
                        )
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(GlassEffectContainerModifier())
        .tint(model.accentColor)
        .environment(\.colorScheme, model.colorScheme)
    }

    private static func tabID(for type: SSHConnectionView.ConnectionType) -> UUID {
        switch type {
        case .profiles: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA001")!
        case .ssh: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA002")!
        case .local: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA003")!
        case .browse: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA004")!
        case .kubernetes: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA005")!
        case .console: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA006")!
        case .vnc: return UUID(uuidString: "8B4B6A50-9128-4D16-B90D-4A2E221AA007")!
        }
    }
}

private final class ConnectionTypeIOS27ScrollController: UIViewController {
    private final class ImmediateControlScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool {
            // The transparent hit targets cover the entire rendered tab. Once
            // a touch moves, cancel the button press so this scroll view owns
            // the drag; a stationary touch still delivers touchUpInside.
            view is UIControl || super.touchesShouldCancel(in: view)
        }
    }

    private let model: ConnectionTypeIOS27Model
    private let scrollView = ImmediateControlScrollView()
    private let hostingController: UIHostingController<ConnectionTypeIOS27GlassStrip>

    var fittingHeight: CGFloat {
        hostingController.sizeThatFits(
            in: CGSize(width: 10_000, height: 1_000)
        ).height
    }

    init(
        types: [SSHConnectionView.ConnectionType],
        selection: SSHConnectionView.ConnectionType,
        selectedBackgroundColor: Color,
        accentColor: Color,
        colorScheme: ColorScheme,
        onSelect: @escaping (SSHConnectionView.ConnectionType) -> Void
    ) {
        let model = ConnectionTypeIOS27Model(
            types: types,
            selection: selection,
            selectedBackgroundColor: selectedBackgroundColor,
            accentColor: accentColor,
            colorScheme: colorScheme,
            onSelect: onSelect
        )
        self.model = model
        self.hostingController = UIHostingController(
            rootView: ConnectionTypeIOS27GlassStrip(model: model)
        )
        super.init(nibName: nil, bundle: nil)
        self.hostingController.sizingOptions = .intrinsicContentSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        addChild(hostingController)
        let hostedView = hostingController.view!
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.backgroundColor = .clear
        scrollView.addSubview(hostedView)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            hostedView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostedView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        scheduleScrollToSelection(animated: false)
    }

    func update(
        types: [SSHConnectionView.ConnectionType],
        selection: SSHConnectionView.ConnectionType,
        selectedBackgroundColor: Color,
        accentColor: Color,
        colorScheme: ColorScheme,
        onSelect: @escaping (SSHConnectionView.ConnectionType) -> Void
    ) {
        let selectionChanged = model.selection != selection
        let typesChanged = model.types != types

        if typesChanged { model.types = types }
        if selectionChanged {
            withAnimation(TabAnimation.selection) {
                model.selection = selection
            }
        }
        if model.selectedBackgroundColor != selectedBackgroundColor {
            model.selectedBackgroundColor = selectedBackgroundColor
        }
        if model.accentColor != accentColor {
            model.accentColor = accentColor
        }
        if model.colorScheme != colorScheme {
            model.colorScheme = colorScheme
        }
        model.onSelect = onSelect

        if selectionChanged || typesChanged {
            scheduleScrollToSelection(animated: true)
        }
    }

    private func scheduleScrollToSelection(animated: Bool) {
        let rawValue = model.selection.rawValue
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            guard let button = self.findButton(
                accessibilityIdentifier: "connection-type-\(rawValue)",
                in: self.hostingController.view
            ) else { return }
            let rect = button.convert(button.bounds, to: self.scrollView).insetBy(dx: -16, dy: 0)
            self.scrollView.scrollRectToVisible(rect, animated: animated)
        }
    }

    private func findButton(
        accessibilityIdentifier: String,
        in view: UIView
    ) -> UIButton? {
        if let button = view as? UIButton,
           button.accessibilityIdentifier == accessibilityIdentifier {
            return button
        }
        for subview in view.subviews {
            if let result = findButton(
                accessibilityIdentifier: accessibilityIdentifier,
                in: subview
            ) {
                return result
            }
        }
        return nil
    }
}

/// Invisible UIKit hit target placed directly over one unchanged SwiftUI glass
/// tab on iOS/iPadOS 27. Remove this when Apple fixes the beta ScrollView tap
/// regression; iOS/iPadOS 26 and earlier continue to use a normal SwiftUI Button.
private struct ConnectionTypeUIKitTapTarget: UIViewRepresentable {
    let type: SSHConnectionView.ConnectionType
    let isSelected: Bool
    let onSelect: (SSHConnectionView.ConnectionType) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ConnectionTypeTapButton {
        let button = ConnectionTypeTapButton(type: type)
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.didTapButton),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ button: ConnectionTypeTapButton, context: Context) {
        context.coordinator.parent = self
        button.accessibilityLabel = type.displayName
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        button.installImmediateTouchBehaviorIfNeeded()
    }

    final class Coordinator: NSObject {
        var parent: ConnectionTypeUIKitTapTarget

        init(parent: ConnectionTypeUIKitTapTarget) {
            self.parent = parent
        }

        @objc func didTapButton() {
            parent.onSelect(parent.type)
        }
    }
}

private final class ConnectionTypeTapButton: UIButton {
    init(type: SSHConnectionView.ConnectionType) {
        super.init(frame: .zero)
        backgroundColor = .clear
        accessibilityIdentifier = "connection-type-\(type.rawValue)"
        accessibilityLabel = type.displayName
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        accessibilityTraits = .button
    }

    override var intrinsicContentSize: CGSize {
        .zero
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installImmediateTouchBehaviorIfNeeded()
    }

    func installImmediateTouchBehaviorIfNeeded() {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollView.delaysContentTouches = false
                scrollView.canCancelContentTouches = true
                return
            }
            ancestor = view.superview
        }
    }
}
#endif

#Preview {
    SSHConnectionView(initialConfig: nil) { config, splitOption in
        //print("Connecting to: \(config.displayName) as \(splitOption.rawValue)")
    }
}
