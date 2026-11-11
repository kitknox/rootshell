//
//  VNCConnectionFormSections.swift
//  rootshell
//
//  Shared Screen Sharing / VNC form: the editable field state, the form
//  sections, and the config builder. Used by both the connect form
//  (SSHConnectionView+VNC) and the profile editor so the two can't drift.
//

import SwiftUI
import rootshellVNC

// MARK: - Jump Selection

/// How the Screen Sharing TCP transport reaches the server.
enum VNCJumpSelection: String, CaseIterable {
    case none
    case sshProfile
    case manual
    case tsshProfile

    var displayName: String {
        switch self {
        case .none: return String(localized: "None", comment: "VNC jump selection")
        case .sshProfile: return String(localized: "SSH Profile", comment: "VNC jump selection")
        case .manual: return String(localized: "Manual SSH", comment: "VNC jump selection")
        case .tsshProfile: return String(localized: "tssh Profile", comment: "VNC jump selection")
        }
    }
}

// MARK: - Form State

/// All user-editable Screen Sharing fields, bound as a single value so the
/// connect form and the profile editor share one source of truth.
struct VNCFormState: Hashable {
    var hostname: String = ""
    var port: String = "5900"
    var username: String = ""
    var password: String = ""
    var savePassword: Bool = true
    var security: VNCConnectionConfig.SecurityPreference = .automatic
    var quality: VNCConnectionConfig.QualityMode = .adaptive
    var highPerformanceBandwidth: VNCConnectionConfig.HighPerformanceBandwidth = .automatic
    var keyboardToolbar: VNCConnectionConfig.KeyboardToolbarPreference = .followAppSetting
    var remoteSystem: VNCConnectionConfig.RemoteSystemPreference = .automatic
    var automaticallyEnterFullScreen: Bool = false

    /// Raw package enum values; nil = package default. Kept raw so the
    /// persisted config stays decoupled from package enum evolution.
    var displaySizingModeRaw: String?
    var displayModeRaw: String?
    var enableRemoteAudio: Bool = true
    var syncVideoToAudio: Bool = false
    var promptForLoginPasswordAtLoginWindow: Bool = true

    /// Action run before an intentional disconnect.
    var preDisconnect = VNCPreDisconnectAction()

    var jumpSelection: VNCJumpSelection = .none
    var jumpSSHProfileID: UUID?
    var jumpTsshProfileID: UUID?

    // Manual jump fields
    var jumpHostname: String = ""
    var jumpPort: String = "22"
    var jumpUsername: String = ""
    var jumpPassword: String = ""
    var saveJumpPassword: Bool = true
    var jumpAuthMethod: SSHConnectionView.AuthType = .key
    var jumpSelectedKeyID: UUID?

    /// Set when a loaded manual jump references a Keychain password, so an
    /// empty password field means "keep the saved one" rather than invalid.
    var jumpHasSavedPassword: Bool = false

    init() {}

    /// Populate from a persisted config (profile editing, suggestion accept,
    /// browse selection).
    init(config: VNCConnectionConfig) {
        hostname = config.host
        port = "\(config.port)"
        username = config.username ?? ""
        security = config.security
        quality = config.quality
        highPerformanceBandwidth = config.highPerformanceBandwidth
        keyboardToolbar = config.keyboardToolbar
        remoteSystem = config.remoteSystem
        automaticallyEnterFullScreen = config.automaticallyEnterFullScreen
        displaySizingModeRaw = config.displaySizingModeRaw
        displayModeRaw = config.displayModeRaw
        enableRemoteAudio = config.enableRemoteAudio
        syncVideoToAudio = config.syncVideoToAudio
        promptForLoginPasswordAtLoginWindow =
            config.promptForLoginPasswordAtLoginWindow
        preDisconnect = config.preDisconnectAction

        switch config.jump {
        case .none:
            jumpSelection = .none
        case .sshProfile(let id):
            jumpSelection = .sshProfile
            jumpSSHProfileID = id
        case .tsshProfile(let id):
            jumpSelection = .tsshProfile
            jumpTsshProfileID = id
        case .sshConfig(let jumpConfig):
            jumpSelection = .manual
            jumpHostname = jumpConfig.host
            jumpPort = "\(jumpConfig.port)"
            jumpUsername = jumpConfig.username
            switch jumpConfig.authMethod {
            case .password(let stored):
                jumpAuthMethod = .password
                jumpPassword = stored
            case .savedPassword:
                jumpAuthMethod = .password
                jumpHasSavedPassword = true
            case .key(let keyID):
                jumpAuthMethod = .key
                jumpSelectedKeyID = keyID
            case .keyboardInteractive:
                jumpAuthMethod = .keyboardInteractive
            case .none, .unknown:
                jumpAuthMethod = .none
            }
        }
    }

    // MARK: Validation

    var isValid: Bool {
        guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let portNum = Int(port), portNum > 0 && portNum <= 65535 else {
            return false
        }

        switch preDisconnect.kind {
        case .shortcut:
            guard preDisconnect.shortcut.isValid else { return false }
        case .command:
            guard preDisconnect.sshProfileID != nil,
                  !preDisconnect.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
        case .none, .lockScreen, .logOut, .controlAltDelete:
            break
        }

        // Jump requirements only apply to the TCP quality modes.
        guard quality != .adaptive else { return true }

        switch jumpSelection {
        case .none:
            return true
        case .sshProfile:
            return jumpSSHProfileID != nil
        case .tsshProfile:
            return jumpTsshProfileID != nil
        case .manual:
            let basicValid = !jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            Int(jumpPort).map { $0 > 0 && $0 <= 65535 } == true

            switch jumpAuthMethod {
            case .password:
                return basicValid && (!jumpPassword.isEmpty || jumpHasSavedPassword)
            case .key:
                return basicValid && jumpSelectedKeyID != nil
            case .keyboardInteractive, .none:
                return basicValid
            }
        }
    }

    // MARK: Config building

    /// Validation failure carrying the user-facing message for the form's
    /// error banner.
    struct BuildError: Error {
        let message: String
    }

    /// Build the config from the form fields, resolving the jump choice
    /// (High Performance is always direct; stale picker state must not leak).
    ///
    /// `sanitizeJumpPasswordForPersistence` moves an inline manual-jump
    /// password into the SSH password Keychain so persisted profiles never
    /// carry inline secrets; the connect flow leaves it inline for the
    /// session and handles saving separately.
    func buildConfig(sanitizeJumpPasswordForPersistence: Bool = false) throws -> VNCConnectionConfig {
        guard let portNum = Int(port), portNum > 0 && portNum <= 65535 else {
            throw BuildError(message: String(localized: "Invalid port number. Must be between 1 and 65535."))
        }

        let trimmedHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw BuildError(message: String(localized: "Please enter a hostname."))
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        switch preDisconnect.kind {
        case .shortcut:
            guard preDisconnect.shortcut.isValid else {
                throw BuildError(message: String(localized: "Please choose a key for the keyboard shortcut sent before disconnecting."))
            }
        case .command:
            guard preDisconnect.sshProfileID != nil else {
                throw BuildError(message: String(localized: "Please select an SSH profile for the command run before disconnecting."))
            }
            guard !preDisconnect.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BuildError(message: String(localized: "Please enter the command to run before disconnecting."))
            }
        case .none, .lockScreen, .logOut, .controlAltDelete:
            break
        }

        let jump: VNCConnectionConfig.Jump
        if quality == .adaptive {
            jump = .none
        } else {
            switch jumpSelection {
            case .none:
                jump = .none

            case .sshProfile:
                guard let profileID = jumpSSHProfileID else {
                    throw BuildError(message: String(localized: "Please select an SSH profile for the jump host."))
                }
                jump = .sshProfile(profileID)

            case .tsshProfile:
                guard let profileID = jumpTsshProfileID else {
                    throw BuildError(message: String(localized: "Please select a tssh profile for the jump host."))
                }
                jump = .tsshProfile(profileID)

            case .manual:
                jump = .sshConfig(try buildManualJumpConfig(
                    sanitizePassword: sanitizeJumpPasswordForPersistence
                ))
            }
        }

        return VNCConnectionConfig(
            host: trimmedHost,
            port: portNum,
            username: trimmedUsername.isEmpty ? nil : trimmedUsername,
            quality: quality,
            highPerformanceBandwidth: highPerformanceBandwidth,
            security: security,
            displaySizingModeRaw: displaySizingModeRaw,
            displayModeRaw: displayModeRaw,
            enableRemoteAudio: enableRemoteAudio,
            syncVideoToAudio: syncVideoToAudio,
            promptForLoginPasswordAtLoginWindow:
                promptForLoginPasswordAtLoginWindow,
            jump: jump,
            keyboardToolbar: keyboardToolbar,
            remoteSystem: remoteSystem,
            automaticallyEnterFullScreen: automaticallyEnterFullScreen,
            preDisconnectAction: preDisconnect.normalized
        )
    }

    private func buildManualJumpConfig(sanitizePassword: Bool) throws -> SSHConfig {
        // A previously saved jump password with an empty field means "keep
        // the Keychain reference" — buildJumpHostConfig would reject it.
        if jumpAuthMethod == .password, jumpPassword.isEmpty, jumpHasSavedPassword {
            guard let jumpPortNum = Int(jumpPort), jumpPortNum > 0 && jumpPortNum <= 65535 else {
                throw BuildError(message: String(localized: "Invalid jump host port number."))
            }
            var jumpSSH = SSHConfig(
                host: jumpHostname.trimmingCharacters(in: .whitespacesAndNewlines),
                port: jumpPortNum,
                username: jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: ""
            )
            jumpSSH.authMethod = .savedPassword
            return jumpSSH
        }

        let jumpHostConfig: SSHConfig.JumpHostConfig?
        do {
            jumpHostConfig = try JumpHostFormSection.buildJumpHostConfig(
                useJumpHost: true,
                hostname: jumpHostname,
                port: jumpPort,
                username: jumpUsername,
                authMethod: jumpAuthMethod,
                password: jumpPassword,
                selectedKeyID: jumpSelectedKeyID,
                sshKeyManager: .shared
            )
        } catch {
            let message = (error as? JumpHostFormSection.BuildError)?.message ?? error.localizedDescription
            throw BuildError(message: message)
        }
        guard let jumpHostConfig else {
            throw BuildError(message: String(localized: "Please enter the jump host details."))
        }

        var jumpSSH = SSHConfig(
            host: jumpHostConfig.host,
            port: jumpHostConfig.port,
            username: jumpHostConfig.username,
            authMethod: jumpHostConfig.authMethod
        )
        jumpSSH.fallbackKeyIDs = jumpHostConfig.fallbackKeyIDs

        // Persisted profiles must never carry an inline secret: move it
        // into the Keychain and store a reference (mirrors the manager's
        // sanitize pass, which doesn't see configs inside the envelope).
        if sanitizePassword, case .password(let inline) = jumpSSH.authMethod, !inline.isEmpty {
            do {
                try SSHPasswordManager.shared.savePassword(
                    inline,
                    host: jumpSSH.host,
                    port: jumpSSH.port,
                    username: jumpSSH.username
                )
                jumpSSH.authMethod = .savedPassword
            } catch {
                // Keychain failure: keep inline rather than losing auth.
            }
        }

        return jumpSSH
    }
}

// MARK: - Form Sections

/// The Screen Sharing form sections (server, auth, quality, jump, keyboard
/// toolbar). Renders as a flat run of Sections; the hosting Form supplies
/// the chrome. Shared by the connect form and the profile editor.
struct VNCConnectionFormSections: View {
    @Binding var form: VNCFormState

    /// Editor mode: a password already exists in the Keychain, so an empty
    /// field means "keep it" and the save toggle turning off removes it.
    var hasSavedPassword: Bool = false

    var body: some View {
        serverSection
        authenticationSection
        qualitySection
        displaySizingSection

        if form.quality == .adaptive {
            audioSection
        } else {
            jumpSection
        }

        sessionPreferencesSection
        preDisconnectSection
    }

    // MARK: Server

    private var serverSection: some View {
        Section("Server") {
            Group {
                TextField("Hostname or IP", text: $form.hostname)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("5900", text: $form.port)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }

                Picker("Remote System", selection: $form.remoteSystem) {
                    ForEach(VNCConnectionConfig.RemoteSystemPreference.allCases, id: \.self) { system in
                        Text(system.displayName).tag(system)
                    }
                }
                Text("Choose Linux for Linux desktops shared with Apple's protocol, such as wayshare on Hyprland, so Option sends Alt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .themedRow()
        }
    }

    // MARK: Authentication

    private var authenticationSection: some View {
        Section {
            Group {
                TextField("Username (optional)", text: $form.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                SecureField("Password", text: $form.password)

                if hasSavedPassword && form.password.isEmpty {
                    Label("Password saved in Keychain. Enter a new one to replace it.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Toggle("Save Password", isOn: $form.savePassword)

                Toggle(
                    "Prompt at Mac Login",
                    isOn: $form.promptForLoginPasswordAtLoginWindow)
                Text("When an Apple Login Window or lock screen is detected, offer to type the saved password after confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Security", selection: $form.security) {
                    ForEach(VNCConnectionConfig.SecurityPreference.allCases, id: \.self) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
            }
            .themedRow()
        } header: {
            Text("Authentication")
        } footer: {
            if hasSavedPassword && !form.savePassword {
                Text("Turning off Save Password removes the saved password when you save.")
            } else {
                Text("Enter the remote account's username for Apple authentication. Leave it empty to sign in with a plain VNC password.")
            }
        }
    }

    // MARK: Quality

    /// Connection-mode split matching the reference GUI: High Performance
    /// (package `.adaptive`, UDP) vs Standard (TCP), with Full Quality as a sub-setting
    /// of Standard rather than a sibling mode.
    private enum ConnectionModeChoice: String, CaseIterable {
        case highPerformance
        case standard

        var displayName: String {
            switch self {
            case .highPerformance: return String(localized: "High Performance", comment: "VNC connection mode")
            case .standard: return String(localized: "Standard", comment: "VNC connection mode")
            }
        }
    }

    private enum StandardQualityChoice: String, CaseIterable {
        case adaptive
        case fullQuality

        var displayName: String {
            switch self {
            case .adaptive: return String(localized: "Adaptive", comment: "VNC standard-mode quality")
            case .fullQuality: return String(localized: "Full Quality", comment: "VNC standard-mode quality")
            }
        }
    }

    /// Switching to High Performance resets the jump choice: it requires
    /// direct UDP reachability, so a tunnel can't apply.
    private var connectionMode: Binding<ConnectionModeChoice> {
        Binding(
            get: { form.quality == .adaptive ? .highPerformance : .standard },
            set: { mode in
                switch mode {
                case .highPerformance:
                    form.quality = .adaptive
                    form.jumpSelection = .none
                case .standard:
                    if form.quality == .adaptive {
                        form.quality = .standard
                    }
                }
            }
        )
    }

    private var standardQuality: Binding<StandardQualityChoice> {
        Binding(
            get: { form.quality == .fullQuality ? .fullQuality : .adaptive },
            set: { choice in
                form.quality = choice == .fullQuality ? .fullQuality : .standard
            }
        )
    }

    private var qualitySection: some View {
        Section {
            Group {
                Picker("Connection Mode", selection: connectionMode) {
                    ForEach(ConnectionModeChoice.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if connectionMode.wrappedValue == .standard {
                    Picker("Quality", selection: standardQuality) {
                        ForEach(StandardQualityChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                } else {
                    Picker("Bandwidth", selection: $form.highPerformanceBandwidth) {
                        ForEach(VNCConnectionConfig.HighPerformanceBandwidth.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                }

                Text(packageQualityMode.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if form.quality == .adaptive {
                    Text(bandwidthExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        } header: {
            Text("Display Quality")
        } footer: {
            if form.quality == .adaptive {
                Text("High Performance uses UDP and cannot be tunneled through SSH.")
            }
        }
    }

    private var bandwidthExplanation: String {
        switch form.highPerformanceBandwidth {
        case .automatic:
            String(localized: "Uses Low Bandwidth on cellular and mesh VPN connections such as Tailscale, and Full otherwise.")
        case .full:
            String(localized: "Asks the Mac for 20 to 60 Mbps. Sharpest motion, but needs a fast, direct network.")
        case .low:
            String(localized: "Asks the Mac for 0.3 to 6 Mbps. Keeps working on slow networks; fast motion looks softer.")
        }
    }

    private var packageQualityMode: VNCConfiguration.VideoQualityMode {
        VNCConfiguration.VideoQualityMode(rawValue: form.quality.rawValue) ?? .standard
    }

    // MARK: Display sizing

    /// Typed views over the raw stored values, defaulted like the package
    /// configuration (Match Client only for High Performance / oneDisplay).
    private var displaySizing: Binding<VNCConfiguration.DisplaySizingMode> {
        Binding(
            get: {
                form.displaySizingModeRaw.flatMap {
                    VNCConfiguration.DisplaySizingMode(rawValue: $0)
                } ?? (form.quality == .adaptive ? .matchClient : .remoteDisplay)
            },
            set: { sizing in
                form.displaySizingModeRaw = sizing.rawValue
                // A stored combined topology would reset sizing to Remote Display.
                if sizing == .matchClient,
                   form.displayModeRaw == VNCConfiguration.DisplayMode.allDisplaysCombined.rawValue {
                    form.displayModeRaw = VNCConfiguration.DisplayMode.oneDisplay.rawValue
                }
            }
        )
    }

    private var displayMode: Binding<VNCConfiguration.DisplayMode> {
        Binding(
            get: {
                form.displayModeRaw.flatMap {
                    VNCConfiguration.DisplayMode(rawValue: $0)
                } ?? .oneDisplay
            },
            set: { form.displayModeRaw = $0.rawValue }
        )
    }

    private var displaySizingSection: some View {
        Section("Remote Display Size") {
            Group {
                if displaySizing.wrappedValue == .matchClient {
                    LabeledContent("Display Mode", value: String(localized: "One Virtual Display"))
                    Text("Match Client creates one client-sized virtual display.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Display Mode", selection: displayMode) {
                        Text(VNCConfiguration.DisplayMode.oneDisplay.title)
                            .tag(VNCConfiguration.DisplayMode.oneDisplay)
                        Text(VNCConfiguration.DisplayMode.allDisplaysCombined.title)
                            .tag(VNCConfiguration.DisplayMode.allDisplaysCombined)
                    }
                }

                Picker("Sizing", selection: displaySizing) {
                    ForEach(VNCConfiguration.DisplaySizingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(displaySizing.wrappedValue.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .themedRow()
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        Section {
            Group {
                Toggle("Play Remote Audio", isOn: $form.enableRemoteAudio)
                if form.enableRemoteAudio {
                    Toggle("Sync Video to Audio", isOn: $form.syncVideoToAudio)
                }
            }
            .themedRow()
        } header: {
            Text("Audio")
        } footer: {
            if form.enableRemoteAudio {
                Text("Sync Video to Audio holds the screen back to match the sound. Better for watching video, slower for everything else.")
            }
        }
    }

    // MARK: Jump host

    private var jumpSection: some View {
        RemoteScreenJumpSection(
            form: $form,
            footer: String(localized: "Tunnel the Screen Sharing connection through an SSH host."))
    }

    // MARK: Session preferences

    private var sessionPreferencesSection: some View {
        Section {
            Group {
                Toggle("Enter Full Screen on Connect", isOn: $form.automaticallyEnterFullScreen)

                // No software keyboard on Mac, so no toolbar to show.
                #if !targetEnvironment(macCatalyst)
                Picker("Keyboard Toolbar", selection: $form.keyboardToolbar) {
                    ForEach(VNCConnectionConfig.KeyboardToolbarPreference.allCases, id: \.self) { preference in
                        Text(toolbarLabel(preference)).tag(preference)
                    }
                }
                #endif
            }
            .themedRow()
        } header: {
            Text("Session")
        } footer: {
            #if targetEnvironment(macCatalyst)
            Text("Full Screen expands this Screen Sharing pane after the connection succeeds.")
            #else
            Text("Full Screen expands this Screen Sharing pane after the connection succeeds. Keyboard Toolbar controls the toolbar above the software keyboard.")
            #endif
        }
    }

    // MARK: Before disconnecting

    /// "Character" row of the key picker; special keys use their raw value.
    private static let characterKeyTag = ""

    private var sshCommandProfiles: [ConnectionProfile] {
        ConnectionProfileManager.shared.profiles.filter(VNCPreDisconnectRunner.canRunCommand(through:))
    }

    private var shortcutKeyChoice: Binding<String> {
        Binding(
            get: { form.preDisconnect.shortcut.specialKey?.rawValue ?? Self.characterKeyTag },
            set: { form.preDisconnect.shortcut.key = $0 }
        )
    }

    /// Keeps the typed key to its last character.
    private var shortcutCharacter: Binding<String> {
        Binding(
            get: { form.preDisconnect.shortcut.character.map(String.init) ?? "" },
            set: { form.preDisconnect.shortcut.key = String($0.suffix(1)) }
        )
    }

    private var preDisconnectSection: some View {
        Section {
            Group {
                Picker("Action", selection: $form.preDisconnect.kind) {
                    ForEach(VNCPreDisconnectAction.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                switch form.preDisconnect.kind {
                case .none, .lockScreen:
                    EmptyView()

                case .logOut:
                    Text("Logs out of the Mac without asking. Apps with unsaved changes can still stop the logout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .controlAltDelete:
                    Text("For Windows and Linux computers. A Mac ignores it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .shortcut:
                    Toggle("Control", isOn: $form.preDisconnect.shortcut.control)
                    Toggle("Option", isOn: $form.preDisconnect.shortcut.option)
                    Toggle("Shift", isOn: $form.preDisconnect.shortcut.shift)
                    Toggle("Command", isOn: $form.preDisconnect.shortcut.command)

                    Picker("Key", selection: shortcutKeyChoice) {
                        Text("Character").tag(Self.characterKeyTag)
                        ForEach(VNCPreDisconnectShortcut.SpecialKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key.rawValue)
                        }
                    }

                    if form.preDisconnect.shortcut.specialKey == nil {
                        HStack {
                            Text("Character")
                            Spacer()
                            TextField("Q", text: shortcutCharacter)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                        }
                    }

                    if form.preDisconnect.shortcut.isValid {
                        LabeledContent("Sends", value: form.preDisconnect.shortcut.displayName)
                    }

                case .command:
                    if sshCommandProfiles.isEmpty {
                        Text("No usable SSH profiles. Create one that signs in with a key or saved password from the Profiles tab first.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("SSH Profile", selection: $form.preDisconnect.sshProfileID) {
                            Text("Select a Profile").tag(UUID?.none)
                            ForEach(sshCommandProfiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                    }

                    TextField("Command", text: $form.preDisconnect.command, axis: .vertical)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .lineLimit(1...4)

                    Text("Runs in the login shell of the SSH profile's user. A command that fails or takes longer than 20 seconds asks before disconnecting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()
        } header: {
            Text("Before Disconnecting")
        } footer: {
            Text("Runs when you close this connection or its tab. It does not run when the connection drops, reconnects, or the app moves to the background.")
        }
    }

    private func toolbarLabel(_ preference: VNCConnectionConfig.KeyboardToolbarPreference) -> String {
        switch preference {
        case .followAppSetting: return String(localized: "Follow App Setting", comment: "VNC keyboard toolbar preference")
        case .on: return String(localized: "On", comment: "VNC keyboard toolbar preference")
        case .off: return String(localized: "Off", comment: "VNC keyboard toolbar preference")
        }
    }
}

// MARK: - Jump Host Section

/// "Connect via" jump picker and fields, shared by the Screen Sharing and KVM
/// forms. Only the `jump*` fields of `form` are read or written.
struct RemoteScreenJumpSection: View {
    @Binding var form: VNCFormState
    let footer: String

    /// Adapter for JumpHostFormSection's enable toggle: "on" means manual
    /// jump is selected; switching it off falls back to a direct connection.
    private var manualJumpEnabled: Binding<Bool> {
        Binding(
            get: { form.jumpSelection == .manual },
            set: { form.jumpSelection = $0 ? .manual : .none }
        )
    }

    private var sshJumpProfiles: [ConnectionProfile] {
        ConnectionProfileManager.shared.profiles.filter { !$0.isDeleted && $0.connectionProtocol == .ssh }
    }

    private var tsshJumpProfiles: [ConnectionProfile] {
        ConnectionProfileManager.shared.profiles.filter { !$0.isDeleted && $0.connectionProtocol == .trzsz }
    }

    var body: some View {
        Section {
            Group {
                Picker("Connect via", selection: $form.jumpSelection) {
                    ForEach(VNCJumpSelection.allCases, id: \.self) { selection in
                        Text(selection.displayName).tag(selection)
                    }
                }

                switch form.jumpSelection {
                case .none:
                    EmptyView()

                case .sshProfile:
                    if sshJumpProfiles.isEmpty {
                        Text("No SSH profiles available. Create one from the Profiles tab first.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("SSH Profile", selection: $form.jumpSSHProfileID) {
                            Text("Select a Profile").tag(UUID?.none)
                            ForEach(sshJumpProfiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                    }

                case .tsshProfile:
                    if tsshJumpProfiles.isEmpty {
                        Text("No tssh profiles available. Create one from the Profiles tab first.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("tssh Profile", selection: $form.jumpTsshProfileID) {
                            Text("Select a Profile").tag(UUID?.none)
                            ForEach(tsshJumpProfiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                    }

                case .manual:
                    JumpHostFormSection(
                        useJumpHost: manualJumpEnabled,
                        hostname: $form.jumpHostname,
                        port: $form.jumpPort,
                        username: $form.jumpUsername,
                        authMethod: $form.jumpAuthMethod,
                        password: $form.jumpPassword,
                        savePassword: $form.saveJumpPassword,
                        selectedKeyID: $form.jumpSelectedKeyID
                    )

                    if form.jumpAuthMethod == .password
                        && form.jumpPassword.isEmpty
                        && form.jumpHasSavedPassword {
                        Label("Jump host password saved in Keychain.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            .themedRow()
        } header: {
            Text("Jump Host")
        } footer: {
            Text(footer)
        }
    }
}
