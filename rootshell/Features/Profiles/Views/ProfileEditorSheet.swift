//
//  ProfileEditorSheet.swift
//  rootshell
//
//  Sheet for creating and editing connection profiles
//

import SwiftUI

/// Sheet for creating or editing a connection profile
struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    // Manager
    private var profileManager: ConnectionProfileManager { ConnectionProfileManager.shared }
    @ObservedObject private var locationDiaryManager = LocationDiaryManager.shared

    // Editing state
    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var iconName: String = "star.fill"
    @State private var colorTag: ProfileColorTag?
    @State private var folderPath: String = ""
    @State private var tags: Set<String> = []
    @State private var newTag: String = ""
    @FocusState private var isTagFieldFocused: Bool

    // Connection protocol state
    @State private var connectionProtocol: ConnectionProtocol = .ssh

    // Keeps the host/username/jump fields when the picker flips between the
    // SSH family and Screen Sharing, which swap one field set for the other
    @State private var endpointCarryOver = ConnectionEndpointCarryOver()

    // Screen Sharing (VNC) state — form fields shared with the connect form
    @State private var vncForm = VNCFormState()
    @State private var hasExistingVNCPassword: Bool = false
    @State private var trzszTransportMode: ProfileTransportMode = .default
    @State private var trzszMTU: String = ""
    @State private var trzszPortMin: String = ""
    @State private var trzszPortMax: String = ""
    @State private var trzszServerPath: String = ""
    @State private var showAdvancedTSSH: Bool = false

    // SSH Config state
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authMethod: AuthMethodType = .key
    @State private var selectedKeyID: UUID?
    @State private var hasExistingPassword: Bool = false
    @State private var isChangingPassword: Bool = false  // true when editing existing password
    @State private var newPassword: String = ""

    // Jump host state
    @State private var useJumpHost: Bool = false
    @State private var jumpHost: String = ""
    @State private var jumpPort: String = "22"
    @State private var jumpUsername: String = ""
    @State private var jumpAuthMethod: AuthMethodType = .key
    @State private var jumpKeyID: UUID?
    @State private var hasExistingJumpPassword: Bool = false
    @State private var isChangingJumpPassword: Bool = false  // true when editing existing jump password
    @State private var newJumpPassword: String = ""

    // Port forwarding state
    @State private var portForwards: [PortForwardConfig.PortForward] = []
    @State private var showingAddPortForward: Bool = false
    @State private var showPortForwardBackgroundAlert: Bool = false

    // Agent forwarding state
    @State private var enableAgentForwarding: Bool = false
    @State private var agentApprovalMode: SSHAgentConfig.ApprovalMode = .perRequest
    @State private var agentForwardAllKeys: Bool = true
    @State private var agentSelectedKeyIDs: Set<UUID> = []

    // GPG agent forwarding state — parallel to SSH agent above.
    // Picker shows SSH keys (via gpgKeygripHex) and imported GPG keys
    // together, since the Assuan layer treats both as signing sources.
    @State private var enableGPGAgentForwarding: Bool = false
    @State private var gpgAgentApprovalMode: GPGAgentConfig.ApprovalMode = .perRequest
    @State private var gpgForwardAllKeys: Bool = true
    @State private var gpgSelectedKeyIDs: Set<UUID> = []
    @State private var gpgRemoteSocketPath: String = GPGAgentConfig.defaultRemoteSocketPath

    // tmux auto-enable state
    @State private var enableTmux: Bool = false

    // tmux launch mode (regular vs control/-CC), meaningful when enableTmux is on
    @State private var tmuxAutoMode: TmuxAutoMode = .regular

    // herdr auto-attach (mutually exclusive with enableTmux via the picker)
    @State private var enableHerdr: Bool = false
    @State private var enableZmx: Bool = false

    // Globals the multiplexer captions fall back to. Observed rather than read
    // directly so the captions refresh when Settings change; the values
    // themselves come from SSHConfig.multiplexerSessionDisplayName.
    @Setting(Settings.Multiplexer.tmuxSessionName) private var tmuxSessionNameSetting
    @Setting(Settings.Multiplexer.tmuxCustomCommand) private var tmuxCustomCommandSetting
    @Setting(Settings.Multiplexer.herdrSessionName) private var herdrSessionNameSetting
    @Setting(Settings.Multiplexer.herdrCustomCommand) private var herdrCustomCommandSetting

    // Launch command state
    @State private var launchCommand: String = ""
    @State private var launchCommandMode: SSHConfig.LaunchCommandMode = .afterConnect

    // TERM override. Empty inherits the global remote default.
    @State private var terminalType: String = ""

    // Multiplexer session name override. Empty inherits the global default for
    // whichever multiplexer the auto-start picker selects.
    @State private var multiplexerSessionName: String = ""

    // VPN state
    @State private var vpnEnabled: Bool = false
    @State private var vpnDNSServers: [String] = []
    @State private var vpnExcludedRoutes: [String] = []
    @State private var vpnBlockQUIC: Bool = false

    // Device override state
    @State private var deviceOverride: DeviceKeyOverride?

    // Load guard — prevents onAppear from resetting state on sub-navigation pops
    @State private var didLoadProfile = false

    // UI state
    @State private var showingIconPicker: Bool = false
    @State private var showingFolderPicker: Bool = false
    @State private var errorMessage: String?

    // Existing profile (nil for new)
    private let existingProfile: ConnectionProfile?
    private let initialFolderPath: String
    private let historyEntry: SSHConnectionHistoryEntry?

    /// When true, omits the NavigationStack wrapper (for embedding in a parent NavigationStack)
    private let embedded: Bool

    enum AuthMethodType: String, CaseIterable {
        case password = "Password"
        case key = "SSH Key"
        case keyboardInteractive = "Keyboard-Interactive"
        case none = "None"

        var displayName: String {
            switch self {
            case .password: return String(localized: "Password", comment: "Auth method: password authentication")
            case .key: return String(localized: "SSH Key", comment: "Auth method: SSH key authentication")
            case .keyboardInteractive: return String(localized: "Keyboard-Interactive", comment: "Auth method: keyboard-interactive (2FA/OTP/PAM)")
            case .none: return String(localized: "None", comment: "Auth method: no authentication")
            }
        }
    }

    // Keyboard-interactive is offered as a toggle under the Password method
    // rather than a fourth picker entry. The picker lists Password/Key/None and
    // shows `.keyboardInteractive` as "Password"; the toggle flips between them.
    private var authMethodPickerCases: [AuthMethodType] {
        AuthMethodType.allCases.filter { $0 != .keyboardInteractive }
    }
    private var targetMethodSelection: Binding<AuthMethodType> {
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
    private var jumpMethodSelection: Binding<AuthMethodType> {
        Binding(
            get: { jumpAuthMethod == .keyboardInteractive ? .password : jumpAuthMethod },
            set: { jumpAuthMethod = $0 }
        )
    }
    private var jumpUsesKeyboardInteractive: Binding<Bool> {
        Binding(
            get: { jumpAuthMethod == .keyboardInteractive },
            set: { jumpAuthMethod = $0 ? .keyboardInteractive : .password }
        )
    }

    /// Create a new profile
    init(folderPath: String = "", embedded: Bool = false) {
        self.existingProfile = nil
        self.initialFolderPath = folderPath
        self.historyEntry = nil
        self.embedded = embedded
    }

    /// Edit an existing profile
    init(profile: ConnectionProfile, embedded: Bool = false) {
        self.existingProfile = profile
        self.initialFolderPath = profile.folderPath
        self.historyEntry = nil
        self.embedded = embedded
    }

    /// Create a profile from a history entry
    init(historyEntry: SSHConnectionHistoryEntry, embedded: Bool = false) {
        self.existingProfile = nil
        self.initialFolderPath = ""
        self.historyEntry = historyEntry
        self.embedded = embedded
    }

    var body: some View {
        if embedded {
            formContent
        } else {
            NavigationStack {
                formContent
            }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            // Profile Info Section
            profileInfoSection

            // Organization Section
            organizationSection

            if connectionProtocol == .vnc {
                // Screen Sharing: protocol picker plus the shared VNC form
                // sections; the SSH-specific sections don't apply.
                vncConnectionSection
                VNCConnectionFormSections(
                    form: $vncForm,
                    hasSavedPassword: hasExistingVNCPassword
                )
            } else {
                // Connection Section
                connectionSection

                // Advanced TSSH Section (only for TSSH protocol)
                if connectionProtocol == .trzsz {
                    advancedTSSHSection
                }

                // Device Override Section (only when editing a profile with an override)
                deviceOverrideSection

                // Jump Host Section
                jumpHostSection

                // Agent Forwarding Section
                agentForwardingSection

                // GPG Agent Forwarding Section — SSH / tssh only. Mosh's
                // UDP transport doesn't carry the Unix-socket forward
                // channel the GPG agent rides on, so showing the toggle
                // there is misleading.
                if connectionProtocol != .mosh {
                    gpgAgentForwardingSection
                }

                // Port Forwarding Section
                portForwardingSection

                #if !CHINA_BUILD
                // VPN Section (SSH and TSSH only, not Mosh)
                if connectionProtocol != .mosh {
                    vpnSection
                }
                #endif

                // Terminal Options Section
                terminalOptionsSection
            }

            // Error display
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle(existingProfile == nil ? "New Profile" : "Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveProfile() }
                    .disabled(!isFormValid)
            }
        }
        .onAppear {
            loadExistingProfile()
        }
        .onChange(of: connectionProtocol) { oldValue, newValue in
            carryEndpointAcrossProtocolChange(from: oldValue, to: newValue)
        }
        .navigationDestination(isPresented: $showingIconPicker) {
            ProfileIconPicker(selectedIcon: $iconName, host: iconHost)
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerSheet(selectedPath: $folderPath)
                .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showingAddPortForward) {
            AddPortForwardSheet { newForward in
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
            .themedSubSheet(sheetThemeColors)
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

    // MARK: - Profile Info Section

    /// Host used for the website-icon option; VNC profiles keep their
    /// endpoint in vncForm, not the SSH host field
    private var iconHost: String {
        connectionProtocol == .vnc ? vncForm.hostname : host
    }

    private var profileInfoSection: some View {
        Section("Profile Info") {
            TextField("Name", text: $name)
                .autocapitalization(.words)
                .themedRow()

            validationMessage(nameValidationMessage)

            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...4)
                .themedRow()

            HStack {
                Text("Icon")
                Spacer()
                Button {
                    showingIconPicker = true
                } label: {
                    HStack {
                        ProfileIconView(
                            storageString: iconName,
                            tint: colorTag.map(color(for:)) ?? .accentColor,
                            host: iconHost
                        )
                        Text(ProfileIconCatalog.displayName(for: ProfileIcon(storageString: iconName)))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .themedRow()

            HStack {
                Text("Color")
                Spacer()
                colorPicker
            }
            .themedRow()
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 8) {
            // None option
            Button {
                colorTag = nil
            } label: {
                Circle()
                    .stroke(Color.secondary, lineWidth: 1)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if colorTag == nil {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
            }
            .buttonStyle(.plain)

            ForEach(ProfileColorTag.allCases, id: \.self) { tag in
                Button {
                    colorTag = tag
                } label: {
                    Circle()
                        .fill(color(for: tag))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if colorTag == tag {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Organization Section

    private var organizationSection: some View {
        Section("Organization") {
            HStack {
                Text("Folder")
                Spacer()
                Button {
                    showingFolderPicker = true
                } label: {
                    HStack {
                        Text(folderPath.isEmpty ? String(localized: "None", comment: "Profile folder: no folder selected") : folderPath)
                            .foregroundColor(folderPath.isEmpty ? .secondary : .primary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .themedRow()

            // Tags
            VStack(alignment: .leading, spacing: 16) {
                Text("Tags")

                if !tags.isEmpty {
                    FlowLayout(spacing: 10) {
                        ForEach(Array(tags).sorted(), id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                    .font(.caption)
                                Button {
                                    tags.remove(tag)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(12)
                        }
                    }
                }

                HStack {
                    TextField("Add tag...", text: $newTag)
                        .autocapitalization(.none)
                        .focused($isTagFieldFocused)
                        .onSubmit {
                            addTag()
                        }

                    Button {
                        isTagFieldFocused = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .themedRow()
        }
    }

    // MARK: - Connection Section

    /// Protocol picker row shared by the SSH connection section and the
    /// Screen Sharing section (which replaces the SSH fields entirely).
    private var protocolPickerRow: some View {
        Picker("Protocol", selection: $connectionProtocol) {
            ForEach(ConnectionProtocol.allCases, id: \.self) { proto in
                Label(proto.displayName, systemImage: proto.iconName).tag(proto)
            }
        }
        .pickerStyle(.menu)
        .themedRow()
    }

    /// Minimal connection section for Screen Sharing profiles: just the
    /// protocol picker; VNCConnectionFormSections renders the rest.
    private var vncConnectionSection: some View {
        Section {
            protocolPickerRow
        } header: {
            Text("Connection")
        } footer: {
            if let protocolConversionNotice {
                Text(protocolConversionNotice)
            }
        }
    }

    /// Saving after a switch across the Screen Sharing boundary replaces the
    /// stored configuration wholesale, so say so before the user commits.
    private var protocolConversionNotice: String? {
        guard let existing = existingProfile,
              (existing.connectionProtocol == .vnc) != (connectionProtocol == .vnc) else {
            return nil
        }
        if connectionProtocol == .vnc {
            return String(
                localized: "Saving replaces this profile's SSH settings (keys, port forwards, agent forwarding, terminal options) with Screen Sharing settings. The hostname is carried over.",
                comment: "Profile editor footer shown when converting an SSH profile to Screen Sharing")
        }
        return String(
            localized: "Saving replaces this profile's Screen Sharing settings (quality, display, audio) with SSH settings. The hostname is carried over.",
            comment: "Profile editor footer shown when converting a Screen Sharing profile to SSH")
    }

    private var connectionSection: some View {
        Section {
            protocolPickerRow

            TextField("Hostname", text: $host)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .themedRow()

            validationMessage(hostValidationMessage)

            HStack {
                Text("Port")
                Spacer()
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            .themedRow()

            validationMessage(portValidationMessage)

            TextField("Username", text: $username)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .themedRow()

            validationMessage(usernameValidationMessage)

            Picker("Authentication", selection: targetMethodSelection) {
                ForEach(authMethodPickerCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .themedRow()

            if authMethod == .key {
                sshKeyPicker(selection: $selectedKeyID, hint: targetKeyHint)
                    .themedRow()
                validationMessage(targetKeyValidationMessage)
            }

            if authMethod == .password || authMethod == .keyboardInteractive {
                Toggle("Keyboard-Interactive (2FA / OTP)", isOn: targetUsesKeyboardInteractive)
                    .themedRow()
            }

            if authMethod == .keyboardInteractive {
                Text("The server will prompt for credentials, such as a one-time code. Used for 2FA/OTP and PAM logins.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }

            if authMethod == .password {
                if isChangingPassword {
                    SecureField(hasExistingPassword ? "Enter new password" : "Enter password", text: $newPassword)
                        .themedRow()
                    Button("Cancel") {
                        newPassword = ""
                        isChangingPassword = false
                    }
                    .foregroundColor(.secondary)
                    .themedRow()
                } else if hasExistingPassword {
                    HStack {
                        Label("Password saved", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Button("Change") {
                            isChangingPassword = true
                        }
                        .buttonStyle(.borderless)
                    }
                    .themedRow()
                    Button("Remove Saved Password", role: .destructive, action: removeTargetPassword)
                        .font(.subheadline)
                        .themedRow()
                } else {
                    Button {
                        isChangingPassword = true
                    } label: {
                        Label("Save Password...", systemImage: "key.fill")
                    }
                    .themedRow()
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let protocolConversionNotice {
                    Text(protocolConversionNotice)
                }
                connectionSectionFooter
            }
        }
    }

    @ViewBuilder
    private var connectionSectionFooter: some View {
        Group {
            if connectionProtocol == .mosh {
                Text("Roam keeps your terminal alive through WiFi handoffs, network switches, and flaky connections. Your session follows you like a loyal sidekick. Uses the mosh protocol under the hood.")
            } else if authMethod == .password {
                if isChangingPassword {
                    Text("Enter password to save securely in Keychain.")
                } else if hasExistingPassword {
                    Text("Password stored securely in Keychain.")
                } else {
                    Text("Password will be prompted each time you connect.")
                }
            } else if authMethod == .key {
                if let keyID = selectedKeyID,
                   !SSHKeyManager.shared.savedKeys.contains(where: { $0.id == keyID }) {
                    Text("This key was configured on another device. Select a local key above, or connect — you'll be prompted to choose a device-specific key.")
                }
            } else if authMethod == .none {
                Text("No password or key required. Used for Tailscale SSH or other pre-authenticated connections.")
            }
        }
    }

    // MARK: - Advanced TSSH Section

    private var advancedTSSHSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvancedTSSH) {
                Picker("Transport", selection: $trzszTransportMode) {
                    ForEach(ProfileTransportMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                HStack {
                    Text("MTU")
                    Spacer()
                    TextField("Default (1400)", text: $trzszMTU)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }

                HStack {
                    Text("Port Min")
                    Spacer()
                    TextField("Default (\(TrzszConfig.preferredUDPPortMin))", text: $trzszPortMin)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }

                HStack {
                    Text("Port Max")
                    Spacer()
                    TextField("Default (\(TrzszConfig.preferredUDPPortMax))", text: $trzszPortMax)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }

                TextField("tsshd Binary (e.g. /usr/local/bin/tsshd)", text: $trzszServerPath)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                if let warning = trzszAdvancedWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .themedRow()
        } header: {
            Text("TSSH")
        } footer: {
            Text("Empty fields inherit from Settings > Roam. tsshd Binary is the full path to the executable on the remote host (e.g. /usr/local/bin/tsshd); leave empty to find tsshd via PATH.")
        }
    }

    /// Validation warning for TSSH advanced fields
    private var trzszAdvancedWarning: String? {
        if let mtu = Int(trzszMTU), (mtu < 100 || mtu > 9000) {
            return "MTU must be between 100 and 9000."
        }
        let portMinVal = Int(trzszPortMin)
        let portMaxVal = Int(trzszPortMax)
        if let min = portMinVal, (min < 1024 || min > 65535) {
            return "Port min must be between 1024 and 65535."
        }
        if let max = portMaxVal, (max < 1024 || max > 65535) {
            return "Port max must be between 1024 and 65535."
        }
        if let min = portMinVal, let max = portMaxVal, min > max {
            return "Port min must not exceed port max."
        }
        return nil
    }

    // MARK: - Device Override Section

    @ViewBuilder
    private var deviceOverrideSection: some View {
        if let override = deviceOverride, let profile = existingProfile {
            Section {
                if let overrideKeyID = override.targetKeyID {
                    HStack {
                        Label("Device Key", systemImage: "iphone")
                        Spacer()
                        if let key = SSHKeyManager.shared.findKey(id: overrideKeyID) {
                            Text(key.name).foregroundStyle(.secondary)
                        } else {
                            Text("Key missing").foregroundStyle(.red)
                        }
                    }
                    .themedRow()
                }
                if let jumpOverrideKeyID = override.jumpHostKeyID {
                    HStack {
                        Label("Jump Host Device Key", systemImage: "iphone")
                        Spacer()
                        if let key = SSHKeyManager.shared.findKey(id: jumpOverrideKeyID) {
                            Text(key.name).foregroundStyle(.secondary)
                        } else {
                            Text("Key missing").foregroundStyle(.red)
                        }
                    }
                    .themedRow()
                }
                if let note = override.note, !note.isEmpty {
                    HStack {
                        Text("Note")
                        Spacer()
                        Text(note).foregroundStyle(.secondary)
                    }
                    .themedRow()
                }
                Button("Remove Device Override", role: .destructive) {
                    let profileID = profile.id
                    DeviceKeyOverrideManager.shared.remove(forTarget: .profile(profileID))
                    deviceOverride = nil
                }
                .themedRow()
            } header: {
                Text("Device Key Override")
            } footer: {
                Text("This device uses a different key than what the profile specifies. This override is local and won't sync.")
            }
        }
    }

    // MARK: - Jump Host Section

    private var jumpHostSection: some View {
        Section {
            Toggle("Use Jump Host", isOn: $useJumpHost)
                .themedRow()

            if useJumpHost {
                TextField("Jump Hostname", text: $jumpHost)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .themedRow()

                validationMessage(jumpHostValidationMessage)

                HStack {
                    Text("Jump Port")
                    Spacer()
                    TextField("22", text: $jumpPort)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                .themedRow()

                validationMessage(jumpPortValidationMessage)

                TextField("Jump Username", text: $jumpUsername)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .themedRow()

                validationMessage(jumpUsernameValidationMessage)

                Picker("Jump Authentication", selection: jumpMethodSelection) {
                    ForEach(authMethodPickerCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .themedRow()

                if jumpAuthMethod == .key {
                    sshKeyPicker(selection: $jumpKeyID, hint: jumpKeyHint)
                        .themedRow()
                    validationMessage(jumpKeyValidationMessage)
                }

                if jumpAuthMethod == .password || jumpAuthMethod == .keyboardInteractive {
                    Toggle("Keyboard-Interactive (2FA / OTP)", isOn: jumpUsesKeyboardInteractive)
                        .themedRow()
                }

                if jumpAuthMethod == .keyboardInteractive {
                    Text("The jump host will prompt for credentials, such as a one-time code.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }

                if jumpAuthMethod == .password {
                    if isChangingJumpPassword {
                        SecureField(hasExistingJumpPassword ? "Enter new password" : "Enter password", text: $newJumpPassword)
                            .themedRow()
                        Button("Cancel") {
                            newJumpPassword = ""
                            isChangingJumpPassword = false
                        }
                        .foregroundColor(.secondary)
                        .themedRow()
                    } else if hasExistingJumpPassword {
                        HStack {
                            Label("Password saved", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Spacer()
                            Button("Change") {
                                isChangingJumpPassword = true
                            }
                            .buttonStyle(.borderless)
                        }
                        .themedRow()
                        Button("Remove Saved Password", role: .destructive, action: removeJumpPassword)
                            .font(.subheadline)
                            .themedRow()
                    } else {
                        Button {
                            isChangingJumpPassword = true
                        } label: {
                            Label("Save Password...", systemImage: "key.fill")
                        }
                        .themedRow()
                    }
                }
            }
        } header: {
            Text("Jump Host")
        } footer: {
            if useJumpHost && jumpAuthMethod == .password {
                if isChangingJumpPassword {
                    Text("Enter password to save securely in Keychain.")
                } else if hasExistingJumpPassword {
                    Text("Jump host password stored securely in Keychain.")
                } else {
                    Text("Jump host password will be prompted on connect.")
                }
            } else {
                Text("Connect through an intermediate server (bastion/proxy)")
            }
        }
    }

    // MARK: - Agent Forwarding Section

    private var agentForwardingSection: some View {
        Section("Agent Forwarding") {
            Toggle("Enable Agent Forwarding", isOn: $enableAgentForwarding.animation())
                .themedRow()

            if enableAgentForwarding {
                // Approval mode picker
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
                .themedRow()

                // Key selection
                let keys = SSHKeyManager.shared.savedKeys
                if keys.isEmpty {
                    HStack {
                        Image(systemName: "key.slash")
                            .foregroundColor(.secondary)
                        Text("No SSH keys available to forward")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                } else {
                    Toggle("Forward All Keys", isOn: $agentForwardAllKeys)
                        .themedRow()

                    if !agentForwardAllKeys {
                        ForEach(keys) { key in
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
                            .themedRow()
                        }
                    }
                }
            }
        }
    }

    // MARK: - GPG Agent Forwarding Section

    private var gpgAgentForwardingSection: some View {
        Section("GPG Agent Forwarding") {
            Toggle("Enable GPG Agent Forwarding", isOn: $enableGPGAgentForwarding.animation())
                .themedRow()

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
                .themedRow()

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
                    Text("`{HOME}` and `{UID}` are resolved at connect time via `id -u` / `$HOME` on the remote.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()

                // SSH keys with cached keygrips qualify alongside any
                // imported GPG keys; the agent treats both as signing
                // sources via the same Assuan path.
                let gpgEligibleSSHKeys = SSHKeyManager.shared.savedKeys.filter { $0.gpgKeygripHex != nil }
                let gpgKeys = GPGKeyManager.shared.savedKeys

                if gpgEligibleSSHKeys.isEmpty && gpgKeys.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("No keys available for GPG forwarding")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                } else {
                    Toggle("Forward All Eligible Keys", isOn: $gpgForwardAllKeys)
                        .themedRow()

                    if !gpgForwardAllKeys {
                        ForEach(gpgEligibleSSHKeys) { key in
                            gpgPickerRow(
                                id: key.id,
                                name: key.name,
                                fingerprint: key.colonFormattedFingerprint,
                                badge: "SSH",
                                badgeColor: .blue
                            )
                            .themedRow()
                        }
                        ForEach(gpgKeys) { key in
                            gpgPickerRow(
                                id: key.id,
                                name: key.name,
                                fingerprint: key.shortPrimaryFingerprint,
                                badge: "GPG",
                                badgeColor: .purple
                            )
                            .themedRow()
                        }
                    }
                }
            }
        }
    }

    /// Shared row renderer for the GPG forwarding key picker —
    /// same shape used by SSHConnectionView. Badge differentiates
    /// SSH keys (promoted via cached keygrip) from imported GPG keys.
    private func gpgPickerRow(
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

    // MARK: - Port Forwarding Section

    private var portForwardingSection: some View {
        Section {
            if portForwards.isEmpty {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundColor(.secondary)
                    Text("No port forwards configured")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            } else {
                ForEach(portForwards) { forward in
                    PortForwardRow(forward: forward) {
                        portForwards.removeAll { $0.id == forward.id }
                    }
                    .themedRow()
                }
            }

            Button {
                showingAddPortForward = true
            } label: {
                Label("Add Port Forward", systemImage: "plus.circle")
            }
            .themedRow()
        } header: {
            Text("Port Forwarding")
        } footer: {
            #if !targetEnvironment(macCatalyst)
            if !portForwards.isEmpty && !locationDiaryManager.isConfigured {
                Text("Port forwards stop when the app is suspended. Enable Location Diary (Auto mode) in Privacy settings, or use iPad Split View.")
            }
            #endif
        }
    }

    // MARK: - VPN Section

    #if !CHINA_BUILD
    private var vpnSection: some View {
        Section("VPN Tunnel") {
            Toggle("Enable VPN", isOn: $vpnEnabled)
                .themedRow()

            #if APPSTORE && targetEnvironment(macCatalyst)
            Label(
                "VPN tunneling on macOS requires the standalone version. Settings configured here will still apply when this profile is used on iOS or iPadOS.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .themedRow()
            #endif

            if vpnEnabled {
                NavigationLink {
                    VPNDNSSettingsView(dnsServers: $vpnDNSServers)
                } label: {
                    LabeledContent("DNS Servers") {
                        Text(vpnDNSServers.isEmpty ? String(localized: "Default", comment: "VPN DNS: using system default") : vpnDNSServers.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()

                NavigationLink {
                    VPNRouteExclusionsView(excludedRoutes: $vpnExcludedRoutes)
                } label: {
                    LabeledContent("Excluded Routes") {
                        Text(vpnExcludedRoutes.isEmpty ? String(localized: "None", comment: "VPN excluded routes: none configured") : String(localized: "\(vpnExcludedRoutes.count) rules", comment: "VPN excluded routes: count"))
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()

                Toggle(isOn: $vpnBlockQUIC) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block HTTP/3 (QUIC)")
                        Text("Forces browsers to HTTP/2 through the tunnel", comment: "VPN block QUIC toggle footnote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()

                // Warn about biometric keys — VPN extension cannot prompt for biometrics
                if hasBiometricKey {
                    Label(
                        "VPN is not compatible with biometric-protected keys. Use a key without biometric auth.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()
                }

                // Warn about biometric passwords — same limitation as keys: the
                // background VPN extension can't present Face ID / passcode, so it
                // can't read a per-use/per-session protected password.
                if hasBiometricPassword {
                    Label(
                        "VPN can't use a biometric-protected password. Save the password without per-use authentication.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()
                }

                // The VPN never prompts for host keys, so it can't start until
                // one was accepted in a regular terminal session.
                if let missingHostKeyHost {
                    Label(
                        "No trusted host key for \(missingHostKeyHost) yet. Connect once in a terminal session so its host key is verified and saved. The VPN won't start without it.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()
                }
            }
        }
    }

    /// First VPN-relevant host (target, then jump) lacking both an accepted
    /// host key and a trusted host CA.
    private var missingHostKeyHost: String? {
        if let port = resolvedPort, !trimmedHost.isEmpty,
           KnownHostsManager.shared.getHost(hostname: trimmedHost, port: port) == nil,
           !HostCAManager.shared.hasCA(forHost: trimmedHost) {
            return trimmedHost
        }
        if useJumpHost, let jumpPort = resolvedJumpPort, !trimmedJumpHost.isEmpty,
           KnownHostsManager.shared.getHost(hostname: trimmedJumpHost, port: jumpPort) == nil,
           !HostCAManager.shared.hasCA(forHost: trimmedJumpHost) {
            return trimmedJumpHost
        }
        return nil
    }
    #endif

    private var hasBiometricKey: Bool {
        guard authMethod == .key, let keyID = selectedKeyID else {
            return false
        }
        let savedKeys = SSHKeyManager.shared.savedKeys
        guard let keyMeta = savedKeys.first(where: { $0.id == keyID }) else {
            return false
        }
        return keyMeta.authRequirement == .perSession || keyMeta.authRequirement == .perUse
    }

    private var hasBiometricPassword: Bool {
        guard authMethod == .password, let port = resolvedPort else {
            return false
        }
        guard let passwordMeta = SSHPasswordManager.shared.findPassword(
            host: trimmedHost,
            port: port,
            username: trimmedUsername
        ) else {
            return false
        }
        return passwordMeta.authRequirement == .perSession || passwordMeta.authRequirement == .perUse
    }

    // MARK: - Terminal Options Section

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

    /// Keep the rare TERM override compact in the main form. Its full value is
    /// available in the destination view, so the summary can remain readable
    /// on narrow phones.
    private var terminalTypeSummary: String {
        let trimmed = terminalType.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Default") : trimmed
    }

    /// Session name the captions describe: the pinned override when set,
    /// otherwise the global the profile inherits.
    private var multiplexerCaptionSessionName: String {
        SSHConfig.multiplexerSessionDisplayName(for: tmuxLaunchSelection.wrappedValue,
                                                override: multiplexerSessionName)
    }

    private var multiplexerSessionSummary: String {
        let trimmed = multiplexerSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "Default")
            : SSHConfig.multiplexerSessionDisplayName(for: tmuxLaunchSelection.wrappedValue,
                                                      override: trimmed)
    }

    private var terminalOptionsSection: some View {
        Section("Terminal Options") {
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
            .themedRow()

            if tmuxLaunchSelection.wrappedValue != .off {
                NavigationLink {
                    ProfileMultiplexerSessionEditor(sessionName: $multiplexerSessionName,
                                                    selection: tmuxLaunchSelection.wrappedValue)
                } label: {
                    LabeledContent("Session Name") {
                        Text(multiplexerSessionSummary)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .themedRow()
            }

            if tmuxLaunchSelection.wrappedValue == .control {
                Text("Start a tmux -CC control-mode gateway for session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            } else if enableTmux {
                Text("Attach to or create tmux session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            } else if enableHerdr {
                Text("Attach to or create herdr session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            } else if enableZmx {
                Text("Attach to or create zmx session \"\(multiplexerCaptionSessionName)\" on connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }

            NavigationLink {
                ProfileTerminalTypeEditor(terminalType: $terminalType)
            } label: {
                LabeledContent("Terminal Type") {
                    Text(terminalTypeSummary)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .themedRow()

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
            .themedRow()
        }
    }

    // MARK: - SSH Key Picker

    @ViewBuilder
    private func sshKeyPicker(selection: Binding<UUID?>, hint: KeyResolutionHint? = nil) -> some View {
        let keys = SSHKeyManager.shared.savedKeys
        let selectedMissing = selection.wrappedValue != nil
            && !keys.contains(where: { $0.id == selection.wrappedValue })

        if selectedMissing {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key not available on this device")
                        .font(.subheadline)
                    if let name = hint?.keyName {
                        Text("Original: \(name)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let fp = hint?.fingerprint {
                        let truncated = String(fp.prefix(12))
                        Text("SHA256:\(truncated)...")
                            .font(.caption2).monospaced().foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        if keys.isEmpty {
            HStack {
                Text("No SSH keys")
                    .foregroundColor(.secondary)
                Spacer()
                NavigationLink("Add Key") {
                    SSHKeyManagementView()
                }
            }
        } else {
            Picker("SSH Key", selection: selection) {
                Text("None").tag(nil as UUID?)
                ForEach(keys) { key in
                    Text(key.name).tag(key.id as UUID?)
                }
            }
        }
    }

    // MARK: - Key Resolution Hints

    private var targetKeyHint: KeyResolutionHint? {
        guard let keyID = selectedKeyID else { return nil }
        return existingProfile?.sshConfig.keyResolutionHints?[keyID.uuidString]
    }

    private var jumpKeyHint: KeyResolutionHint? {
        guard let keyID = jumpKeyID else { return nil }
        return existingProfile?.sshConfig.keyResolutionHints?[keyID.uuidString]
            ?? existingProfile?.sshConfig.jumpHost?.keyResolutionHints?[keyID.uuidString]
    }

    // MARK: - Password Actions

    private func startEditingPassword() {
        isChangingPassword = true
    }

    private func cancelEditingPassword() {
        newPassword = ""
        isChangingPassword = false
    }

    private func removeTargetPassword() {
        guard let port = resolvedPort else {
            errorMessage = portValidationMessage
            return
        }
        let key = SSHSavedPassword.makeConnectionKey(
            host: trimmedHost,
            port: port,
            username: trimmedUsername
        )
        try? SSHPasswordManager.shared.deletePassword(connectionKey: key)
        hasExistingPassword = false
        isChangingPassword = false
        newPassword = ""
    }

    private func startEditingJumpPassword() {
        isChangingJumpPassword = true
    }

    private func cancelEditingJumpPassword() {
        newJumpPassword = ""
        isChangingJumpPassword = false
    }

    private func removeJumpPassword() {
        guard let port = resolvedJumpPort else {
            errorMessage = jumpPortValidationMessage
            return
        }
        let key = SSHSavedPassword.makeConnectionKey(
            host: trimmedJumpHost,
            port: port,
            username: trimmedJumpUsername
        )
        try? SSHPasswordManager.shared.deletePassword(connectionKey: key)
        hasExistingJumpPassword = false
        isChangingJumpPassword = false
        newJumpPassword = ""
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        if connectionProtocol == .vnc {
            return nameValidationMessage == nil && vncForm.isValid
        }
        return nameValidationMessage == nil &&
        hostValidationMessage == nil &&
        portValidationMessage == nil &&
        usernameValidationMessage == nil &&
        targetKeyValidationMessage == nil &&
        (!useJumpHost || isJumpHostValid)
    }

    private var isJumpHostValid: Bool {
        jumpHostValidationMessage == nil &&
        jumpPortValidationMessage == nil &&
        jumpUsernameValidationMessage == nil &&
        jumpKeyValidationMessage == nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedJumpHost: String {
        jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedJumpUsername: String {
        jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedPort: Int? {
        resolvedPort(from: port)
    }

    private var resolvedJumpPort: Int? {
        resolvedPort(from: jumpPort)
    }

    private func resolvedPort(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 22 }
        guard let port = Int(trimmed), (1...65535).contains(port) else { return nil }
        return port
    }

    private var nameValidationMessage: String? {
        trimmedName.isEmpty ? "Name is required." : nil
    }

    private var hostValidationMessage: String? {
        trimmedHost.isEmpty ? "Hostname is required." : nil
    }

    private var portValidationMessage: String? {
        resolvedPort == nil ? "Port must be between 1 and 65535, or blank for 22." : nil
    }

    private var usernameValidationMessage: String? {
        trimmedUsername.isEmpty ? "Username is required." : nil
    }

    private var targetKeyValidationMessage: String? {
        authMethod == .key && selectedKeyID == nil
            ? "Select an SSH key or choose another authentication method."
            : nil
    }

    private var jumpHostValidationMessage: String? {
        useJumpHost && trimmedJumpHost.isEmpty ? "Jump hostname is required." : nil
    }

    private var jumpPortValidationMessage: String? {
        useJumpHost && resolvedJumpPort == nil
            ? "Jump port must be between 1 and 65535, or blank for 22."
            : nil
    }

    private var jumpUsernameValidationMessage: String? {
        useJumpHost && trimmedJumpUsername.isEmpty ? "Jump username is required." : nil
    }

    private var jumpKeyValidationMessage: String? {
        useJumpHost && jumpAuthMethod == .key && jumpKeyID == nil
            ? "Select an SSH key for the jump host or choose another authentication method."
            : nil
    }

    @ViewBuilder
    private func validationMessage(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .themedRow()
        }
    }

    // MARK: - Protocol switching

    /// Screen Sharing replaces the SSH fields wholesale, so flipping the
    /// picker would otherwise blank the host the user just typed. Carry the
    /// shared endpoint across in whichever direction the switch went.
    private func carryEndpointAcrossProtocolChange(
        from oldValue: ConnectionProtocol,
        to newValue: ConnectionProtocol
    ) {
        // SSH / Roam / tssh all share one field set, so nothing to carry.
        guard (oldValue == .vnc) != (newValue == .vnc) else { return }

        if newValue == .vnc {
            var destination = vncForm.endpoint
            // The saved-password flag lives outside the form state.
            destination.hasHostBoundSecret = destination.hasHostBoundSecret || hasExistingVNCPassword
            endpointCarryOver.carry(from: sshEndpoint, into: &destination, side: .screenSharing)
            vncForm.endpoint = destination
        } else {
            var destination = sshEndpoint
            endpointCarryOver.carry(from: vncForm.endpoint, into: &destination, side: .sshFamily)
            applySSHEndpoint(destination)
        }
    }

    /// The SSH-family fields in the shared endpoint shape.
    private var sshEndpoint: ConnectionEndpoint {
        ConnectionEndpoint(
            host: host,
            username: username,
            usesJumpHost: useJumpHost,
            jumpHost: jumpHost,
            jumpPort: jumpPort,
            jumpUsername: jumpUsername,
            jumpAuthMethod: Self.sharedAuthType(jumpAuthMethod),
            jumpKeyID: jumpKeyID,
            jumpHasSavedPassword: hasExistingJumpPassword,
            hasHostBoundSecret: hasExistingPassword
                || !newPassword.isEmpty
                || hasExistingJumpPassword
                || !newJumpPassword.isEmpty
        )
    }

    private func applySSHEndpoint(_ endpoint: ConnectionEndpoint) {
        host = endpoint.host
        username = endpoint.username

        useJumpHost = endpoint.usesJumpHost
        guard endpoint.usesJumpHost else {
            hasExistingJumpPassword = false
            return
        }
        jumpHost = endpoint.jumpHost
        jumpPort = endpoint.jumpPort
        jumpUsername = endpoint.jumpUsername
        jumpAuthMethod = Self.editorAuthType(endpoint.jumpAuthMethod)
        jumpKeyID = endpoint.jumpKeyID
        hasExistingJumpPassword = endpoint.jumpHasSavedPassword
    }

    /// The editor and the Screen Sharing form spell the same auth choices
    /// with two enums; map explicitly rather than leaning on raw values.
    private static func sharedAuthType(_ method: AuthMethodType) -> SSHConnectionView.AuthType {
        switch method {
        case .password: return .password
        case .key: return .key
        case .keyboardInteractive: return .keyboardInteractive
        case .none: return .none
        }
    }

    private static func editorAuthType(_ method: SSHConnectionView.AuthType) -> AuthMethodType {
        switch method {
        case .password: return .password
        case .key: return .key
        case .keyboardInteractive: return .keyboardInteractive
        case .none: return .none
        }
    }

    // MARK: - Actions

    private func loadExistingProfile() {
        guard !didLoadProfile else { return }
        didLoadProfile = true

        // Check for existing profile first
        if let profile = existingProfile {
            name = profile.name
            notes = profile.notes ?? ""
            iconName = profile.iconName ?? "star.fill"
            colorTag = profile.colorTag
            folderPath = profile.folderPath
            tags = profile.tags

            // Load connection protocol and transport mode
            connectionProtocol = profile.connectionProtocol
            trzszTransportMode = profile.trzszTransportMode

            // Screen Sharing profiles: populate the VNC form and skip the
            // SSH field loading (sshConfig is a display-only placeholder)
            if profile.connectionProtocol == .vnc {
                if let vncConfig = profile.vncConfig {
                    vncForm = VNCFormState(config: vncConfig)
                    hasExistingVNCPassword = VNCPasswordManager.shared.hasPassword(for: vncConfig)
                }
                return
            }

            // Load TSSH advanced settings
            if let mtu = profile.trzszMTU { trzszMTU = "\(mtu)" }
            if let portMin = profile.trzszPortMin { trzszPortMin = "\(portMin)" }
            if let portMax = profile.trzszPortMax { trzszPortMax = "\(portMax)" }
            if let serverPath = profile.trzszServerPath { trzszServerPath = serverPath }
            // Auto-expand advanced section if any override is set
            if profile.trzszMTU != nil || profile.trzszPortMin != nil || profile.trzszPortMax != nil || profile.trzszServerPath != nil {
                showAdvancedTSSH = true
            }

            let config = profile.sshConfig
            host = config.host
            port = "\(config.port)"
            username = config.username

            switch config.authMethod {
            case .password:
                authMethod = .password
            case .savedPassword:
                authMethod = .password
                // Check if password actually exists in Keychain
                hasExistingPassword = SSHPasswordManager.shared.hasPassword(
                    host: config.host,
                    port: config.port,
                    username: config.username
                )
            case .key(let keyID):
                authMethod = .key
                if let resolved = SSHKeyManager.shared.resolveKey(
                    id: keyID, hint: config.keyResolutionHints?[keyID.uuidString]
                ) {
                    selectedKeyID = resolved.id
                } else {
                    selectedKeyID = keyID  // Keep original — picker will show "missing" warning
                }
            case .none:
                authMethod = .none  // Tailscale/WireGuard pre-authenticated
            case .keyboardInteractive:
                authMethod = .keyboardInteractive
            case .unknown:
                authMethod = .none  // Newer app's auth type; shown as None (re-pick to change)
            }

            if let jump = config.jumpHost {
                useJumpHost = true
                jumpHost = jump.host
                jumpPort = "\(jump.port)"
                jumpUsername = jump.username

                switch jump.authMethod {
                case .password:
                    jumpAuthMethod = .password
                case .savedPassword:
                    jumpAuthMethod = .password
                    // Check if password actually exists in Keychain
                    hasExistingJumpPassword = SSHPasswordManager.shared.hasPassword(
                        host: jump.host,
                        port: jump.port,
                        username: jump.username
                    )
                case .key(let keyID):
                    jumpAuthMethod = .key
                    let jumpHint = config.keyResolutionHints?[keyID.uuidString]
                        ?? jump.keyResolutionHints?[keyID.uuidString]
                    if let resolved = SSHKeyManager.shared.resolveKey(id: keyID, hint: jumpHint) {
                        jumpKeyID = resolved.id
                    } else {
                        jumpKeyID = keyID
                    }
                case .none:
                    jumpAuthMethod = .none  // Tailscale/WireGuard pre-authenticated
                case .keyboardInteractive:
                    jumpAuthMethod = .keyboardInteractive
                case .unknown:
                    jumpAuthMethod = .none  // Newer app's auth type; shown as None
                }
            }

            // Load device override
            deviceOverride = DeviceKeyOverrideManager.shared.override(forProfile: profile.id)

            // Load agent forwarding
            enableAgentForwarding = config.agentConfig.enabled
            agentApprovalMode = config.agentConfig.approvalMode
            agentForwardAllKeys = config.agentConfig.forwardedKeyIDs.isEmpty
            agentSelectedKeyIDs = config.agentConfig.forwardedKeyIDs

            // Load GPG agent forwarding
            enableGPGAgentForwarding = config.gpgAgentConfig.enabled
            gpgAgentApprovalMode = config.gpgAgentConfig.approvalMode
            gpgForwardAllKeys = config.gpgAgentConfig.forwardedKeyIDs.isEmpty
            gpgSelectedKeyIDs = config.gpgAgentConfig.forwardedKeyIDs
            gpgRemoteSocketPath = config.gpgAgentConfig.remoteSocketPath

            // Load port forwarding
            portForwards = config.portForwardConfig.forwards

            // Load multiplexer settings
            enableTmux = config.tmuxAutoEnable
            tmuxAutoMode = config.tmuxAutoMode
            enableHerdr = config.herdrAutoEnable
            enableZmx = config.zmxAutoEnable

            // Load launch command
            launchCommand = config.launchCommand ?? ""
            launchCommandMode = config.launchCommandMode

            // Load the TERM override
            terminalType = config.terminalType ?? ""

            // Load the multiplexer session override
            multiplexerSessionName = config.multiplexerSessionName ?? ""

            // Load VPN settings
            vpnEnabled = profile.vpnEnabled
            vpnDNSServers = profile.vpnDNSServers
            vpnExcludedRoutes = profile.vpnExcludedRoutes
            vpnBlockQUIC = profile.vpnBlockQUIC
            return
        }

        // Check for history entry to pre-fill
        if let entry = historyEntry {
            // Use display string as suggested name
            name = entry.displayString
            host = entry.host
            port = "\(entry.port)"
            username = entry.username

            // Load connection protocol from history
            connectionProtocol = entry.connectionProtocol ?? .ssh

            switch entry.authType {
            case .password:
                authMethod = .password
            case .savedPassword:
                authMethod = .password
                // Check if password actually exists in Keychain
                hasExistingPassword = SSHPasswordManager.shared.hasPassword(
                    host: entry.host,
                    port: entry.port,
                    username: entry.username
                )
            case .key(let keyID, _):
                authMethod = .key
                selectedKeyID = keyID
            case .none:
                authMethod = .none  // Tailscale/WireGuard pre-authenticated
            case .keyboardInteractive:
                authMethod = .keyboardInteractive
            case .unknown:
                authMethod = .none  // Newer app's auth type; shown as None (re-pick to change)
            }

            // Jump host from history
            if let jHost = entry.jumpHost, !jHost.isEmpty {
                useJumpHost = true
                jumpHost = jHost
                jumpPort = "\(entry.jumpPort ?? 22)"
                jumpUsername = entry.jumpUsername ?? entry.username

                if let jumpAuth = entry.jumpAuthType {
                    switch jumpAuth {
                    case .password:
                        jumpAuthMethod = .password
                    case .savedPassword:
                        jumpAuthMethod = .password
                        // Check if password actually exists in Keychain
                        hasExistingJumpPassword = SSHPasswordManager.shared.hasPassword(
                            host: jHost,
                            port: entry.jumpPort ?? 22,
                            username: entry.jumpUsername ?? entry.username
                        )
                    case .key(let keyID, _):
                        jumpAuthMethod = .key
                        jumpKeyID = keyID
                    case .keyboardInteractive:
                        jumpAuthMethod = .keyboardInteractive
                    case .none:
                        jumpAuthMethod = .none  // Tailscale/WireGuard pre-authenticated
                    case .unknown:
                        jumpAuthMethod = .none  // Newer app's auth type; shown as None
                    }
                }
            }

            // Agent config from history
            if let agentConfig = entry.agentConfig {
                enableAgentForwarding = agentConfig.enabled
                agentApprovalMode = agentConfig.approvalMode
                agentForwardAllKeys = agentConfig.forwardedKeyIDs.isEmpty
                agentSelectedKeyIDs = agentConfig.forwardedKeyIDs
            }

            // GPG agent config from history. Else-branch resets state
            // so picking a legacy entry after an enabled one doesn't
            // leak the previous selection into the new profile.
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

            // Port forwarding from history
            if let pfConfig = entry.portForwardConfig {
                portForwards = pfConfig.forwards
            }

            // Multiplexer settings from history
            enableTmux = entry.tmuxAutoEnable ?? false
            tmuxAutoMode = entry.tmuxAutoMode ?? .regular
            enableHerdr = entry.herdrAutoEnable ?? false
            enableZmx = entry.zmxAutoEnable ?? false

            // Launch command from history
            launchCommand = entry.launchCommand ?? ""
            launchCommandMode = entry.launchCommandMode ?? .afterConnect

            // TERM override from history
            terminalType = entry.terminalType ?? ""
            multiplexerSessionName = entry.multiplexerSessionName ?? ""
            return
        }

        // New profile - use initial folder path
        folderPath = initialFolderPath
    }

    private func saveProfile() {
        errorMessage = nil

        if connectionProtocol == .vnc {
            saveVNCProfile()
            return
        }

        guard let portNum = resolvedPort else {
            errorMessage = portValidationMessage
            return
        }
        let targetHost = trimmedHost
        let targetUsername = trimmedUsername

        // Build SSH config
        let sshAuthMethod: SSHConfig.AuthMethod
        switch authMethod {
        case .password:
            if !newPassword.isEmpty {
                // New password entered - save it
                do {
                    try SSHPasswordManager.shared.savePassword(
                        newPassword,
                        host: targetHost,
                        port: portNum,
                        username: targetUsername
                    )
                    sshAuthMethod = .savedPassword
                } catch {
                    errorMessage = "Failed to save password: \(error.localizedDescription)"
                    return
                }
            } else if hasExistingPassword {
                // Keep existing saved password
                sshAuthMethod = .savedPassword
            } else {
                // No password saved - prompt on connect
                sshAuthMethod = .password("")
            }
        case .key:
            sshAuthMethod = .key(selectedKeyID!)
        case .keyboardInteractive:
            sshAuthMethod = .keyboardInteractive
        case .none:
            sshAuthMethod = .none  // Tailscale/WireGuard pre-authenticated
        }

        let jumpPortNum: Int
        if useJumpHost {
            guard let resolved = resolvedJumpPort else {
                errorMessage = jumpPortValidationMessage
                return
            }
            jumpPortNum = resolved
        } else {
            jumpPortNum = 22
        }
        let targetJumpHost = trimmedJumpHost
        let targetJumpUsername = trimmedJumpUsername

        var jumpHostConfig: SSHConfig.JumpHostConfig?
        if useJumpHost {
            let jumpAuth: SSHConfig.AuthMethod
            switch jumpAuthMethod {
            case .password:
                if !newJumpPassword.isEmpty {
                    // New password entered - save it
                    do {
                        try SSHPasswordManager.shared.savePassword(
                            newJumpPassword,
                            host: targetJumpHost,
                            port: jumpPortNum,
                            username: targetJumpUsername
                        )
                        jumpAuth = .savedPassword
                    } catch {
                        errorMessage = "Failed to save jump host password: \(error.localizedDescription)"
                        return
                    }
                } else if hasExistingJumpPassword {
                    // Keep existing saved password
                    jumpAuth = .savedPassword
                } else {
                    // No password saved - prompt on connect
                    jumpAuth = .password("")
                }
            case .key:
                jumpAuth = .key(jumpKeyID!)
            case .keyboardInteractive:
                jumpAuth = .keyboardInteractive
            case .none:
                jumpAuth = .none  // Tailscale/WireGuard pre-authenticated
            }

            // Build fallback keys for jump host
            let jumpFallbackIDs: [UUID]?
            if case .key(let keyID) = jumpAuth {
                jumpFallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
            } else {
                jumpFallbackIDs = nil
            }

            jumpHostConfig = SSHConfig.JumpHostConfig(
                host: targetJumpHost,
                port: jumpPortNum,
                username: targetJumpUsername,
                authMethod: jumpAuth,
                fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
            )
        }

        // Build agent config
        let agentConfig: SSHAgentConfig
        if enableAgentForwarding {
            let forwardedKeys = agentForwardAllKeys ? Set<UUID>() : agentSelectedKeyIDs
            agentConfig = SSHAgentConfig(
                enabled: true,
                approvalMode: agentApprovalMode,
                forwardedKeyIDs: forwardedKeys
            )
        } else {
            agentConfig = .disabled
        }

        // Build port forward config
        let portForwardConfig = PortForwardConfig(forwards: portForwards)

        let sshConfig = SSHConfig(
            host: targetHost,
            port: portNum,
            username: targetUsername,
            password: "",  // Never store passwords
            cachedIP: nil,
            jumpHost: jumpHostConfig,
            hssShorthand: nil,
            cloudInstanceLabel: nil,
            agentConfig: agentConfig,
            portForwardConfig: portForwardConfig,
            tmuxAutoEnable: enableTmux,
            tmuxAutoMode: effectiveTmuxAutoMode,
            launchCommand: launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : launchCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            launchCommandMode: launchCommandMode
        )

        // Update auth method after init
        var finalConfig = sshConfig
        finalConfig.authMethod = sshAuthMethod
        finalConfig.herdrAutoEnable = enableHerdr
        finalConfig.zmxAutoEnable = enableZmx

        // TERM override. Empty (or malformed) means inherit the global default
        // rather than pinning a value that would silently fall back anyway.
        let trimmedTerminalType = terminalType.trimmingCharacters(in: .whitespacesAndNewlines)
        finalConfig.terminalType = TerminalTypeSettings.isValid(trimmedTerminalType) ? trimmedTerminalType : nil

        // Same rule for the multiplexer session name: store only a value that
        // is legal for either multiplexer, so switching the picker can't leave
        // a name behind that silently falls back.
        let trimmedSessionName = multiplexerSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        finalConfig.multiplexerSessionName =
            SSHConfig.isEmbeddableMultiplexerSessionName(trimmedSessionName) ? trimmedSessionName : nil
        // GPG forwarding from the form. Now that the editor has a
        // full GPG section we drive this from the @State vars
        // instead of passing through the existing profile's value.
        // Mosh hides the GPG section but the @State persists, so we
        // also gate on connectionProtocol — otherwise a profile that
        // had GPG on, then switched to Mosh, would keep `enabled:
        // true` in the saved profile despite no way to act on it.
        if enableGPGAgentForwarding && connectionProtocol != .mosh {
            let trimmedPath = gpgRemoteSocketPath.trimmingCharacters(in: .whitespaces)
            finalConfig.gpgAgentConfig = GPGAgentConfig(
                enabled: true,
                approvalMode: gpgAgentApprovalMode,
                forwardedKeyIDs: gpgForwardAllKeys ? [] : gpgSelectedKeyIDs,
                remoteSocketPath: trimmedPath.isEmpty
                    ? GPGAgentConfig.defaultRemoteSocketPath
                    : trimmedPath
            )
        } else {
            finalConfig.gpgAgentConfig = .disabled
        }

        // Populate key resolution hints for cross-device sync
        finalConfig.keyResolutionHints = KeyResolutionHint.hints(for: finalConfig)

        do {
            if let existing = existingProfile {
                // Update existing profile
                var updated = existing
                updated.name = trimmedName
                updated.notes = notes.isEmpty ? nil : notes
                updated.iconName = iconName
                updated.colorTag = colorTag
                updated.folderPath = folderPath
                updated.tags = tags
                updated.sshConfig = finalConfig
                updated.connectionProtocol = connectionProtocol
                updated.trzszTransportMode = trzszTransportMode
                updated.trzszMTU = Int(trzszMTU)
                updated.trzszPortMin = Int(trzszPortMin)
                updated.trzszPortMax = Int(trzszPortMax)
                let trimmedServerPath = trzszServerPath.trimmingCharacters(in: .whitespaces)
                updated.trzszServerPath = trimmedServerPath.isEmpty ? nil : trimmedServerPath
                updated.vpnEnabled = vpnEnabled
                updated.vpnDNSServers = vpnDNSServers
                updated.vpnExcludedRoutes = vpnExcludedRoutes
                updated.vpnBlockQUIC = vpnBlockQUIC
                // Switching a Screen Sharing profile to an SSH-family
                // protocol drops the stale VNC config from the envelope.
                updated.vncConfig = nil
                try profileManager.updateProfile(updated)
            } else {
                // Create new profile
                try profileManager.createProfile(
                    name: trimmedName,
                    sshConfig: finalConfig,
                    connectionProtocol: connectionProtocol,
                    trzszTransportMode: trzszTransportMode,
                    trzszMTU: Int(trzszMTU),
                    trzszPortMin: Int(trzszPortMin),
                    trzszPortMax: Int(trzszPortMax),
                    trzszServerPath: {
                        let trimmed = trzszServerPath.trimmingCharacters(in: .whitespaces)
                        return trimmed.isEmpty ? nil : trimmed
                    }(),
                    notes: notes.isEmpty ? nil : notes,
                    iconName: iconName,
                    colorTag: colorTag,
                    folderPath: folderPath,
                    tags: tags,
                    vpnEnabled: vpnEnabled,
                    vpnDNSServers: vpnDNSServers,
                    vpnExcludedRoutes: vpnExcludedRoutes,
                    vpnBlockQUIC: vpnBlockQUIC
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Save a Screen Sharing profile: config into the extension envelope,
    /// placeholder sshConfig, password to the VNC Keychain only.
    private func saveVNCProfile() {
        let config: VNCConnectionConfig
        do {
            config = try vncForm.buildConfig(sanitizeJumpPasswordForPersistence: true)
        } catch {
            errorMessage = (error as? VNCFormState.BuildError)?.message ?? error.localizedDescription
            return
        }

        // Password handling: a typed password replaces the saved one when
        // the toggle is on; toggling save off removes any saved password.
        // Blank field with the toggle on keeps the existing entry.
        if vncForm.savePassword {
            if !vncForm.password.isEmpty {
                do {
                    try VNCPasswordManager.shared.savePassword(vncForm.password, for: config)
                } catch {
                    errorMessage = "Failed to save password: \(error.localizedDescription)"
                    return
                }
            }
        } else {
            try? VNCPasswordManager.shared.deletePassword(for: config)
        }

        do {
            if let existing = existingProfile {
                var updated = existing
                updated.name = trimmedName
                updated.notes = notes.isEmpty ? nil : notes
                updated.iconName = iconName
                updated.colorTag = colorTag
                updated.folderPath = folderPath
                updated.tags = tags
                updated.connectionProtocol = .vnc
                updated.vncConfig = config
                updated.sshConfig = ConnectionProfile.vncPlaceholderSSHConfig(for: config)
                try profileManager.updateProfile(updated)
            } else {
                try profileManager.createProfile(
                    name: trimmedName,
                    sshConfig: ConnectionProfile.vncPlaceholderSSHConfig(for: config),
                    connectionProtocol: .vnc,
                    notes: notes.isEmpty ? nil : notes,
                    iconName: iconName,
                    colorTag: colorTag,
                    folderPath: folderPath,
                    tags: tags,
                    extensionPayload: ProfileExtensionPayload(vncConfig: config)
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        tags.insert(trimmed)
        newTag = ""
    }

    private func color(for tag: ProfileColorTag) -> Color {
        switch tag {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

// MARK: - Profile Terminal Type Editor

/// Keeps the uncommon per-profile TERM override out of the main profile form
/// while still making the inherited value and safer common choices explicit.
private struct ProfileTerminalTypeEditor: View {
    @Binding var terminalType: String
    @State private var isCustom: Bool

    init(terminalType: Binding<String>) {
        _terminalType = terminalType

        let initialValue = terminalType.wrappedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _isCustom = State(initialValue:
            !initialValue.isEmpty && !TerminalTypeSettings.presets.contains(initialValue)
        )
    }

    private var trimmedTerminalType: String {
        terminalType.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customWarning: String? {
        guard isCustom else { return nil }
        return TerminalTypeSettings.warning(for: terminalType)
    }

    var body: some View {
        Form {
            Section {
                terminalTypeChoice(
                    title: String(localized: "Use Global Default"),
                    detail: TerminalTypeSettings.remote,
                    isSelected: !isCustom && trimmedTerminalType.isEmpty
                ) {
                    isCustom = false
                    terminalType = ""
                }

                ForEach(TerminalTypeSettings.presets, id: \.self) { preset in
                    terminalTypeChoice(
                        title: preset,
                        usesMonospacedFont: true,
                        isSelected: !isCustom && trimmedTerminalType == preset
                    ) {
                        isCustom = false
                        terminalType = preset
                    }
                }

                terminalTypeChoice(
                    title: String(localized: "Custom"),
                    isSelected: isCustom
                ) {
                    isCustom = true
                }

                if isCustom {
                    TextField("Terminal type", text: $terminalType)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .themedRow()

                    if let customWarning {
                        Label(customWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .themedRow()
                    }
                }
            } header: {
                Text("TERM Value")
            } footer: {
                Text("This profile normally inherits the remote terminal type from Settings. Override it only for hosts that require a different terminfo name.")
            }
        }
        .themedList()
        .navigationTitle("Terminal Type")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func terminalTypeChoice(
        title: String,
        detail: String? = nil,
        usesMonospacedFont: Bool = false,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(usesMonospacedFont ? .system(.body, design: .monospaced) : .body)
                    if let detail {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedRow()
    }
}

private struct ProfileMultiplexerSessionEditor: View {
    @Binding var sessionName: String
    let selection: TmuxLaunchSelection

    @Setting(Settings.Multiplexer.tmuxSessionName) private var tmuxSessionNameSetting
    @Setting(Settings.Multiplexer.tmuxCustomCommand) private var tmuxCustomCommandSetting
    @Setting(Settings.Multiplexer.herdrSessionName) private var herdrSessionNameSetting
    @Setting(Settings.Multiplexer.herdrCustomCommand) private var herdrCustomCommandSetting
    @Setting(Settings.Multiplexer.zmxSessionName) private var zmxSessionNameSetting
    @Setting(Settings.Multiplexer.zmxCustomCommand) private var zmxCustomCommandSetting

    @State private var isCustom: Bool

    init(sessionName: Binding<String>, selection: TmuxLaunchSelection) {
        _sessionName = sessionName
        self.selection = selection
        _isCustom = State(initialValue:
            !sessionName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var isHerdr: Bool { selection == .herdr }
    private var isZmx: Bool { selection == .zmx }

    private var trimmed: String {
        sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The global this profile inherits when no override is set, shown as the
    /// detail on the "Use Global Default" row.
    private var globalDetail: String {
        if isHerdr {
            let name = herdrSessionNameSetting.trimmingCharacters(in: .whitespacesAndNewlines)
            return SSHConfig.isEmbeddableHerdrSessionName(name) ? name : "default"
        }
        if isZmx {
            let name = zmxSessionNameSetting.trimmingCharacters(in: .whitespacesAndNewlines)
            return SSHConfig.isEmbeddableZmxSessionName(name) ? name : SSHConfig.zmxDefaultSessionName
        }
        let name = tmuxSessionNameSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "main" : name
    }

    /// The Settings command override for whichever multiplexer the picker
    /// selected. Reading the wrong one here would disable the field for a
    /// command the connection will never run.
    private var customCommandSetting: String {
        if isHerdr { return herdrCustomCommandSetting }
        if isZmx { return zmxCustomCommandSetting }
        return tmuxCustomCommandSetting
    }

    /// A full-command override in Settings replaces the session name outright,
    /// so pinning one here would do nothing.
    private var hasCustomCommand: Bool {
        !customCommandSetting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var customWarning: String? {
        guard isCustom, !trimmed.isEmpty else { return nil }
        if isZmx {
            guard !SSHConfig.isEmbeddableZmxSessionName(trimmed) else { return nil }
            // A leading `-` passes the shared charset rule but `zmx attach`
            // reads it as a flag, so name the real problem rather than sending
            // the user hunting for an illegal character that isn't there.
            if trimmed.hasPrefix("-") {
                return String(localized: "zmx reads a name starting with '-' as an option. This name falls back to the global default.")
            }
            return String(localized: "Use letters, digits, and . _ - only, up to 64 characters. Other names fall back to the global default.")
        }
        guard !SSHConfig.isEmbeddableMultiplexerSessionName(trimmed) else { return nil }
        return String(localized: "Use letters, digits, and . _ - only, up to 64 characters. Other names fall back to the global default.")
    }

    var body: some View {
        Form {
            Section {
                sessionChoice(
                    title: String(localized: "Use Global Default"),
                    detail: globalDetail,
                    isSelected: !isCustom
                ) {
                    isCustom = false
                    sessionName = ""
                }

                sessionChoice(title: String(localized: "Custom"), isSelected: isCustom) {
                    isCustom = true
                }

                if isCustom {
                    TextField("Session name", text: $sessionName)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .disabled(hasCustomCommand)
                        .foregroundStyle(hasCustomCommand ? .secondary : .primary)
                        .themedRow()

                    if let customWarning {
                        Label(customWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .themedRow()
                    }
                }
            } header: {
                Text("Session Name")
            } footer: {
                if hasCustomCommand {
                    Text("Ignored when a custom auto-start command is set in Settings.")
                } else if isHerdr {
                    Text("The herdr session this profile attaches to on connect. Leave on the global default to use the session name from Settings. Names may use letters, numbers, '.', '_' and '-' (\".\" and \"..\" alone are reserved).")
                } else if isZmx {
                    Text("The zmx session this profile attaches to or creates on connect. Leave on the global default to use the session name from Settings. Names may use letters, numbers, '.', '_' and '-', and may not start with '-'.")
                } else {
                    Text("The tmux session this profile attaches to or creates on connect. Leave on the global default to use the session name from Settings. A pinned name also overrides the session you were last attached to on this host.")
                }
            }
        }
        .themedList()
        .navigationTitle("Session Name")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sessionChoice(
        title: String,
        detail: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedRow()
    }
}

// MARK: - Flow Layout (for tags)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

// MARK: - Folder Picker Sheet

struct FolderPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Binding var selectedPath: String
    @State private var newFolderName: String = ""
    @State private var showingNewFolder: Bool = false

    private var profileManager: ConnectionProfileManager { ConnectionProfileManager.shared }

    private var normalizedNewFolderPath: String {
        ConnectionProfile.normalizeFolderPath(newFolderName.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            List {
                // Root option
                Button {
                    selectedPath = ""
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "house.fill")
                            .foregroundColor(.accentColor)
                        Text("Root (No Folder)")
                        Spacer()
                        if selectedPath.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()

                // Existing folders
                ForEach(profileManager.allFolders) { folder in
                    Button {
                        selectedPath = folder.path
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(folder.path)
                            Spacer()
                            if selectedPath == folder.path {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }

                // New folder option
                Section {
                    if showingNewFolder {
                        HStack {
                            TextField("Folder name", text: $newFolderName)
                                .autocapitalization(.words)
                            Button("Create") {
                                if !normalizedNewFolderPath.isEmpty {
                                    selectedPath = normalizedNewFolderPath
                                    dismiss()
                                }
                            }
                            .disabled(normalizedNewFolderPath.isEmpty)
                        }
                        .themedRow()
                    } else {
                        Button {
                            showingNewFolder = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
