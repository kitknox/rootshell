//
//  SerializableConnectionConfig.swift
//  rootshell
//
//  Codable connection config that strips passwords before serialization.
//  Used for state restoration - passwords are not persisted.
//

import Foundation

/// Codable connection config that strips passwords before serialization
nonisolated struct SerializableConnectionConfig: Codable, Equatable, Sendable {
    nonisolated enum ConfigType: String, Codable, Sendable {
        case local
        case ssh
        case mosh
        case trzsz
        case kubernetes
        case console
        case ec2Console
        case shellLaunchedSSH
        case shellLaunchedMosh
        case shellLaunchedTrzsz
        case vnc
    }

    let type: ConfigType
    let localWorkingDirectory: String?
    let sshConfig: SSHConfigSafe?
    let moshConfig: MoshConfigSafe?
    let trzszConfig: TrzszConfigSafe?
    let kubernetesConfig: KubernetesNodeShellConfig?
    let consoleConfig: ConsoleConfig?
    let ec2ConsoleConfig: EC2ConsoleConfig?
    let shellWorkingDirectory: String?  // For shell-launched sessions
    // Optional so window state written before this field decodes as nil
    let vncConfig: VNCConfigSafe?

    /// Mosh config with password cleared for safe persistence
    nonisolated struct MoshConfigSafe: Codable, Equatable, Sendable {
        let sshConfig: SSHConfigSafe
        let udpPortMin: Int
        let udpPortMax: Int
        let predictionMode: MoshConfig.PredictionMode
        let predictOverwrite: Bool
        let colors: Int
        let serverPath: String?
        let serverArgs: [String]

        init(from config: MoshConfig) {
            self.sshConfig = SSHConfigSafe(from: config.sshConfig)
            self.udpPortMin = config.udpPortMin
            self.udpPortMax = config.udpPortMax
            self.predictionMode = config.predictionMode
            self.predictOverwrite = config.predictOverwrite
            self.colors = config.colors
            self.serverPath = config.serverPath
            self.serverArgs = config.serverArgs
        }

        // @MainActor: builds a live MoshConfig (whose init is MainActor) via
        // toSSHConfig(); the Codable conformance stays nonisolated.
        @MainActor
        func toMoshConfig() -> MoshConfig {
            var config = MoshConfig(sshConfig: sshConfig.toSSHConfig())
            config.udpPortMin = udpPortMin
            config.udpPortMax = udpPortMax
            config.predictionMode = predictionMode
            config.predictOverwrite = predictOverwrite
            config.colors = colors
            config.serverPath = serverPath
            config.serverArgs = serverArgs
            return config
        }

        /// Whether this config needs a password to be entered before connecting
        var needsPassword: Bool {
            sshConfig.needsPassword
        }

        private enum CodingKeys: String, CodingKey {
            case sshConfig
            case udpPortMin
            case udpPortMax
            case predictionMode
            case predictOverwrite
            case colors
            case serverPath
            case serverArgs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sshConfig = try container.decode(SSHConfigSafe.self, forKey: .sshConfig)
            udpPortMin = try container.decode(Int.self, forKey: .udpPortMin)
            udpPortMax = try container.decode(Int.self, forKey: .udpPortMax)
            predictionMode = try container.decode(MoshConfig.PredictionMode.self, forKey: .predictionMode)
            predictOverwrite = try container.decodeIfPresent(Bool.self, forKey: .predictOverwrite) ?? false
            colors = try container.decode(Int.self, forKey: .colors)
            serverPath = try container.decodeIfPresent(String.self, forKey: .serverPath)
            serverArgs = try container.decode([String].self, forKey: .serverArgs)
        }
    }

    /// Trzsz config with password cleared for safe persistence
    nonisolated struct TrzszConfigSafe: Codable, Equatable, Sendable {
        let sshConfig: SSHConfigSafe
        let transportMode: TrzszConfig.TransportMode
        let udpPortMin: Int
        let udpPortMax: Int
        let serverPath: String?

        init(from config: TrzszConfig) {
            self.sshConfig = SSHConfigSafe(from: config.sshConfig)
            self.transportMode = config.transportMode
            self.udpPortMin = config.udpPortMin
            self.udpPortMax = config.udpPortMax
            self.serverPath = config.serverPath
        }

        // @MainActor: builds a live TrzszConfig (MainActor init); Codable stays nonisolated.
        @MainActor
        func toTrzszConfig() -> TrzszConfig {
            TrzszConfig(
                sshConfig: sshConfig.toSSHConfig(),
                transportMode: transportMode,
                udpPortMin: udpPortMin,
                udpPortMax: udpPortMax,
                serverPath: serverPath
            )
        }

        /// Whether this config needs a password to be entered before connecting
        var needsPassword: Bool {
            sshConfig.needsPassword
        }
    }

    /// SSH config with password cleared for safe persistence
    nonisolated struct SSHConfigSafe: Codable, Equatable, Sendable {
        let host: String
        let port: Int
        let username: String
        let authMethod: AuthMethodSafe
        let cachedIP: String?
        let jumpHost: JumpHostConfigSafe?
        let hssShorthand: String?
        let cloudInstanceLabel: String?
        let agentConfig: SSHAgentConfig
        /// GPG agent forwarding config. Optional for backward compat —
        /// older serialized profiles decode as nil and we apply
        /// `.disabled` on restore.
        let gpgAgentConfig: GPGAgentConfig?
        let portForwardConfig: PortForwardConfig
        let tmuxAutoEnable: Bool?
        let tmuxAutoMode: TmuxAutoMode?
        /// herdr auto-attach. Optional for backward compat — older serialized
        /// sessions decode as nil and restore as disabled.
        let herdrAutoEnable: Bool?
        /// herdr launch mode. Optional for backward compat; nil restores as
        /// regular.
        let herdrAutoMode: HerdrAutoMode?
        let zmxAutoEnable: Bool?
        let launchCommand: String?
        let launchCommandMode: SSHConfig.LaunchCommandMode?
        /// Per-connection TERM override. Optional for backward compat — older
        /// serialized sessions decode as nil and inherit the global default.
        let terminalType: String?
        /// Per-profile multiplexer session name. Optional for backward compat —
        /// older serialized sessions decode as nil and use the global default.
        let multiplexerSessionName: String?

        /// Auth method that doesn't store actual passwords
        nonisolated enum AuthMethodSafe: Codable, Equatable, Sendable {
            case passwordRequired  // Password was used but not stored
            case key(UUID)         // SSH key ID
            case none              // No authentication (Tailscale/WireGuard pre-authenticated)
        }

        /// Jump host config without password
        nonisolated struct JumpHostConfigSafe: Codable, Equatable, Sendable {
            var tsshRelay: TSSHRelaySettings? = nil
            let host: String
            let port: Int
            let username: String
            let authMethod: AuthMethodSafe
        }

        init(from config: SSHConfig) {
            self.host = config.host
            self.port = config.port
            self.username = config.username
            self.cachedIP = config.cachedIP
            self.hssShorthand = config.hssShorthand
            self.cloudInstanceLabel = config.cloudInstanceLabel
            self.agentConfig = config.agentConfig
            self.gpgAgentConfig = config.gpgAgentConfig
            self.portForwardConfig = config.portForwardConfig
            self.tmuxAutoEnable = config.tmuxAutoEnable
            self.tmuxAutoMode = config.tmuxAutoMode
            self.herdrAutoEnable = config.herdrAutoEnable
            self.herdrAutoMode = config.herdrAutoMode
            self.zmxAutoEnable = config.zmxAutoEnable
            self.launchCommand = config.launchCommand
            self.launchCommandMode = config.launchCommandMode
            self.terminalType = config.terminalType
            self.multiplexerSessionName = config.multiplexerSessionName

            // Convert auth method, stripping passwords
            switch config.authMethod {
            case .password:
                self.authMethod = .passwordRequired
            case .savedPassword:
                self.authMethod = .passwordRequired  // Saved password still requires password entry when restoring
            case .key(let id):
                self.authMethod = .key(id)
            case .none:
                self.authMethod = .none
            case .keyboardInteractive, .unknown:
                // Restoring via VPN-shared config needs user interaction; surface
                // as password-required rather than attempting a silent restore.
                self.authMethod = .passwordRequired
            }

            // Convert jump host if present
            if let jump = config.jumpHost {
                let jumpAuth: AuthMethodSafe
                switch jump.authMethod {
                case .password:
                    jumpAuth = .passwordRequired
                case .savedPassword:
                    jumpAuth = .passwordRequired  // Saved password still requires password entry when restoring
                case .key(let id):
                    jumpAuth = .key(id)
                case .none:
                    jumpAuth = .none
                case .keyboardInteractive, .unknown:
                    jumpAuth = .passwordRequired
                }
                self.jumpHost = JumpHostConfigSafe(
                    tsshRelay: jump.tsshRelay,
                    host: jump.host,
                    port: jump.port,
                    username: jump.username,
                    authMethod: jumpAuth
                )
            } else {
                self.jumpHost = nil
            }
        }

        /// Convert back to SSHConfig, leaving password empty.
        /// @MainActor: builds a live SSHConfig (MainActor init) and reads
        /// `SSHKeyManager.shared` for fallback keys; Codable stays nonisolated.
        @MainActor
        func toSSHConfig() -> SSHConfig {
            let authMethod: SSHConfig.AuthMethod
            switch self.authMethod {
            case .passwordRequired:
                authMethod = .password("")  // Empty - will need re-entry
            case .key(let id):
                authMethod = .key(id)
            case .none:
                authMethod = .none
            }

            var config = SSHConfig(
                host: host,
                port: port,
                username: username,
                password: ""
            )
            config.authMethod = authMethod
            config.cachedIP = cachedIP
            config.hssShorthand = hssShorthand
            config.cloudInstanceLabel = cloudInstanceLabel
            config.agentConfig = agentConfig
            // gpgAgentConfig is optional on the safe form so older
            // serialized profiles decode cleanly — fall back to
            // .disabled when absent.
            config.gpgAgentConfig = gpgAgentConfig ?? .disabled
            config.portForwardConfig = portForwardConfig
            config.tmuxAutoEnable = tmuxAutoEnable ?? false
            config.tmuxAutoMode = tmuxAutoMode ?? .regular
            config.herdrAutoEnable = herdrAutoEnable ?? false
            config.herdrAutoMode = herdrAutoMode ?? .regular
            config.zmxAutoEnable = zmxAutoEnable ?? false
            config.launchCommand = launchCommand
            config.launchCommandMode = launchCommandMode ?? .afterConnect
            config.terminalType = terminalType
            config.multiplexerSessionName = multiplexerSessionName

            if let jump = jumpHost {
                let jumpAuth: SSHConfig.AuthMethod
                switch jump.authMethod {
                case .passwordRequired:
                    jumpAuth = .password("")
                case .key(let id):
                    jumpAuth = .key(id)
                case .none:
                    jumpAuth = .none
                }

                // Build fallback keys for jump host
                let jumpFallbackIDs: [UUID]?
                if case .key(let keyID) = jumpAuth {
                    jumpFallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
                } else {
                    jumpFallbackIDs = nil
                }

                config.jumpHost = SSHConfig.JumpHostConfig(
                    host: jump.host,
                    port: jump.port,
                    username: jump.username,
                    authMethod: jumpAuth,
                    fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
                )
                config.jumpHost?.tsshRelay = jump.tsshRelay
            }

            return config
        }

        /// Whether this config needs a password to be entered before connecting
        var needsPassword: Bool {
            if case .passwordRequired = authMethod { return true }
            if let jump = jumpHost, case .passwordRequired = jump.authMethod { return true }
            return false
        }

        /// Whether the jump host specifically needs a password
        var jumpHostNeedsPassword: Bool {
            if let jump = jumpHost, case .passwordRequired = jump.authMethod { return true }
            return false
        }

        /// Whether the target host specifically needs a password
        var targetNeedsPassword: Bool {
            if case .passwordRequired = authMethod { return true }
            return false
        }
    }

    /// VNC config safe for persistence. The VNC password itself is a runtime
    /// Keychain lookup and never touches this struct; only a jump host's
    /// inline SSH config needs stripping, routed through SSHConfigSafe.
    nonisolated struct VNCConfigSafe: Codable, Equatable, Sendable {
        let host: String
        let port: Int
        let username: String?
        let quality: VNCConnectionConfig.QualityMode
        let security: VNCConnectionConfig.SecurityPreference
        let displaySizingModeRaw: String?
        let displayModeRaw: String?
        let enableRemoteAudio: Bool
        /// Optional keeps window-state decoding compatible with builds that
        /// predate login detection. Missing values default on in live configs.
        let promptForLoginPasswordAtLoginWindow: Bool?
        let jump: JumpSafe
        let keyboardToolbar: VNCConnectionConfig.KeyboardToolbarPreference
        /// Optional keeps window-state decoding compatible with builds that
        /// predate the profile setting. Live configs always materialize it.
        let automaticallyEnterFullScreen: Bool?

        /// Jump routing with the inline SSH config password-stripped.
        nonisolated enum JumpSafe: Codable, Equatable, Sendable {
            case none
            case sshProfile(UUID)
            case sshConfig(SSHConfigSafe)
            case tsshProfile(UUID)
        }

        init(from config: VNCConnectionConfig) {
            self.host = config.host
            self.port = config.port
            self.username = config.username
            self.quality = config.quality
            self.security = config.security
            self.displaySizingModeRaw = config.displaySizingModeRaw
            self.displayModeRaw = config.displayModeRaw
            self.enableRemoteAudio = config.enableRemoteAudio
            self.promptForLoginPasswordAtLoginWindow =
                config.promptForLoginPasswordAtLoginWindow
            self.keyboardToolbar = config.keyboardToolbar
            self.automaticallyEnterFullScreen = config.automaticallyEnterFullScreen
            switch config.jump {
            case .none:
                self.jump = .none
            case .sshProfile(let id):
                self.jump = .sshProfile(id)
            case .sshConfig(let ssh):
                self.jump = .sshConfig(SSHConfigSafe(from: ssh))
            case .tsshProfile(let id):
                self.jump = .tsshProfile(id)
            }
        }

        // @MainActor: builds a live VNCConnectionConfig (MainActor type) and
        // may build an SSHConfig via toSSHConfig(); Codable stays nonisolated.
        @MainActor
        func toVNCConfig() -> VNCConnectionConfig {
            let liveJump: VNCConnectionConfig.Jump
            switch jump {
            case .none:
                liveJump = .none
            case .sshProfile(let id):
                liveJump = .sshProfile(id)
            case .sshConfig(let safe):
                liveJump = .sshConfig(safe.toSSHConfig())
            case .tsshProfile(let id):
                liveJump = .tsshProfile(id)
            }
            return VNCConnectionConfig(
                host: host,
                port: port,
                username: username,
                quality: quality,
                security: security,
                displaySizingModeRaw: displaySizingModeRaw,
                displayModeRaw: displayModeRaw,
                enableRemoteAudio: enableRemoteAudio,
                promptForLoginPasswordAtLoginWindow:
                    promptForLoginPasswordAtLoginWindow ?? true,
                jump: liveJump,
                keyboardToolbar: keyboardToolbar,
                automaticallyEnterFullScreen: automaticallyEnterFullScreen ?? false
            )
        }

        /// Only a jump host's SSH auth can need re-entry; the VNC password
        /// is resolved from the Keychain at connect time.
        var needsPassword: Bool {
            if case .sshConfig(let safe) = jump { return safe.needsPassword }
            return false
        }
    }

    init(from config: ConnectionConfig) {
        switch config {
        case .local(let cwd):
            self.type = .local
            self.localWorkingDirectory = cwd
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .ssh(let ssh):
            self.type = .ssh
            self.localWorkingDirectory = nil
            self.sshConfig = SSHConfigSafe(from: ssh)
            self.moshConfig = nil
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .mosh(let mosh):
            self.type = .mosh
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = MoshConfigSafe(from: mosh)
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .trzsz(let trzsz):
            self.type = .trzsz
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = TrzszConfigSafe(from: trzsz)
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .kubernetes(let k8s):
            self.type = .kubernetes
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = nil
            // Store the config but note that session ID will be regenerated on restore
            self.kubernetesConfig = k8s
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .console(let console):
            self.type = .console
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            // Store the config but note that session ID will be regenerated on restore
            self.consoleConfig = console
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .ec2Console(let ec2):
            self.type = .ec2Console
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            // Store the config but note that session ID will be regenerated on restore
            self.ec2ConsoleConfig = ec2
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .shellLaunchedSSH(let ssh, let shellCwd):
            self.type = .shellLaunchedSSH
            self.localWorkingDirectory = nil
            self.sshConfig = SSHConfigSafe(from: ssh)
            self.moshConfig = nil
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = shellCwd
            self.vncConfig = nil

        case .shellLaunchedMosh(let mosh, let shellCwd):
            self.type = .shellLaunchedMosh
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = MoshConfigSafe(from: mosh)
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = shellCwd
            self.vncConfig = nil

        case .shellLaunchedTrzsz(let trzsz, let shellCwd):
            self.type = .shellLaunchedTrzsz
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = TrzszConfigSafe(from: trzsz)
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = shellCwd
            self.vncConfig = nil

        case .trzszTransfer:
            // A live Continuity transfer can't be persisted — the
            // payload (sessionID, certs, scrollback) lives only in
            // memory and the originator already detached. Fall back
            // to a local shell so window-state restore doesn't fail
            // closed when the app is killed mid-transfer.
            self.type = .local
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = nil

        case .vnc(let vnc):
            self.type = .vnc
            self.localWorkingDirectory = nil
            self.sshConfig = nil
            self.moshConfig = nil
            self.trzszConfig = nil
            self.kubernetesConfig = nil
            self.consoleConfig = nil
            self.ec2ConsoleConfig = nil
            self.shellWorkingDirectory = nil
            self.vncConfig = VNCConfigSafe(from: vnc)
        }
    }

    /// Convert back to ConnectionConfig
    /// Note: For ephemeral resources (K8s, Console, EC2), this generates fresh session IDs
    /// @MainActor: dispatches to the live-config builders above (toSSHConfig/
    /// toMoshConfig/toTrzszConfig). Called from `@MainActor` restore paths.
    @MainActor
    func toConnectionConfig() -> ConnectionConfig {
        switch type {
        case .local:
            return .local(workingDirectory: localWorkingDirectory)

        case .ssh:
            guard let ssh = sshConfig else { return .local() }
            return .ssh(ssh.toSSHConfig())

        case .mosh:
            guard let mosh = moshConfig else { return .local() }
            return .mosh(mosh.toMoshConfig())

        case .trzsz:
            guard let trzsz = trzszConfig else { return .local() }
            return .trzsz(trzsz.toTrzszConfig())

        case .kubernetes:
            guard let k8s = kubernetesConfig else { return .local() }
            // Generate fresh session ID - pods are ephemeral
            return .kubernetes(k8s.withNewSession())

        case .console:
            guard let console = consoleConfig else { return .local() }
            // Generate fresh session ID - WebSocket sessions are ephemeral
            return .console(console.withNewSession())

        case .ec2Console:
            guard let ec2 = ec2ConsoleConfig else { return .local() }
            // Generate fresh session ID - ephemeral SSH keys are used
            return .ec2Console(ec2.withNewSession())

        case .shellLaunchedSSH:
            guard let ssh = sshConfig else { return .local() }
            // Shell-launched SSH: will auto-reconnect and return to shell on exit
            return .shellLaunchedSSH(sshConfig: ssh.toSSHConfig(), shellWorkingDirectory: shellWorkingDirectory)

        case .shellLaunchedMosh:
            guard let mosh = moshConfig else { return .local() }
            // Shell-launched Mosh: will auto-reconnect and return to shell on exit
            return .shellLaunchedMosh(moshConfig: mosh.toMoshConfig(), shellWorkingDirectory: shellWorkingDirectory)

        case .shellLaunchedTrzsz:
            guard let trzsz = trzszConfig else { return .local() }
            // Shell-launched Trzsz: will auto-reconnect and return to shell on exit
            return .shellLaunchedTrzsz(trzszConfig: trzsz.toTrzszConfig(), shellWorkingDirectory: shellWorkingDirectory)

        case .vnc:
            guard let vnc = vncConfig else { return .local() }
            return .vnc(vnc.toVNCConfig())
        }
    }

    /// Whether this config needs user input (password) before reconnecting
    var needsUserInput: Bool {
        sshConfig?.needsPassword
            ?? moshConfig?.needsPassword
            ?? trzszConfig?.needsPassword
            ?? vncConfig?.needsPassword
            ?? false
    }

    /// Display name for UI
    var displayName: String {
        switch type {
        case .local:
            return "Local Shell"
        case .ssh:
            return sshConfig.map { "\($0.username)@\($0.host)" } ?? "SSH"
        case .mosh:
            return moshConfig.map { "roam \($0.sshConfig.username)@\($0.sshConfig.host)" } ?? "Roam"
        case .trzsz:
            return trzszConfig.map { "roam \($0.sshConfig.username)@\($0.sshConfig.host)" } ?? "Roam"
        case .kubernetes:
            return kubernetesConfig?.displayName ?? "Kubernetes"
        case .console:
            return consoleConfig?.displayName ?? "Console"
        case .ec2Console:
            return ec2ConsoleConfig?.displayName ?? "EC2 Console"
        case .shellLaunchedSSH:
            return sshConfig.map { "\($0.username)@\($0.host)" } ?? "SSH"
        case .shellLaunchedMosh:
            return moshConfig.map { "roam \($0.sshConfig.username)@\($0.sshConfig.host)" } ?? "Roam"
        case .shellLaunchedTrzsz:
            return trzszConfig.map { "roam \($0.sshConfig.username)@\($0.sshConfig.host)" } ?? "Roam"
        case .vnc:
            return vncConfig.map { "vnc \($0.host)" } ?? "Screen Sharing"
        }
    }
}
