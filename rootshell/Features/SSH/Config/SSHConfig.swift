import Foundation

/// Which flavor of tmux to launch when auto-start is enabled.
/// Only meaningful when `SSHConfig.tmuxAutoEnable` is true.
nonisolated enum TmuxAutoMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Plain interactive session: `tmux new-session -A`.
    case regular

    /// Control mode gateway: `tmux -CC new-session -A`. Requires a raw byte
    /// transport (SSH / trzsz-tssh); not usable over Mosh.
    case control
}

extension TmuxAutoMode {
    static let discoveryAttachStorageKey = "tmuxDiscoveryAttachMode"

    static var persistedDiscoveryAttachMode: TmuxAutoMode {
        get {
            SettingsStore.shared.value(Settings.Multiplexer.tmuxDiscoveryAttachMode)
        }
        set {
            // Nonisolated setter; the store's local-change observer picks the write up.
            UserDefaults.standard.set(newValue.rawValue, forKey: discoveryAttachStorageKey)
        }
    }
}

/// UI-facing selection for the mutually exclusive auto-start options.
enum TmuxLaunchSelection: Hashable, CaseIterable {
    case off
    case regular
    case control
    case herdr
    case zmx

    init(tmuxEnabled: Bool, mode: TmuxAutoMode, herdrEnabled: Bool, zmxEnabled: Bool) {
        if tmuxEnabled {
            self = (mode == .control) ? .control : .regular
        } else if herdrEnabled {
            self = .herdr
        } else if zmxEnabled {
            self = .zmx
        } else {
            self = .off
        }
    }

    /// Whether tmux auto-start is on.
    var tmuxEnabled: Bool { self == .regular || self == .control }

    /// Whether herdr auto-start is on.
    var herdrEnabled: Bool { self == .herdr }

    /// Whether zmx auto-start is on.
    var zmxEnabled: Bool { self == .zmx }

    /// The persisted tmux launch mode (regular when tmux is off, which is
    /// irrelevant then).
    var mode: TmuxAutoMode { self == .control ? .control : .regular }
}

/// Configuration for an SSH connection
struct SSHConfig: Codable, Hashable {
    enum RemoteCommandPolicy: String, Sendable {
        case verbatim
        case prependPATH
    }

    nonisolated enum LaunchCommandMode: String, Codable, CaseIterable, Hashable, Sendable {
        /// Send the launch command as terminal input after the session is ready.
        case afterConnect

        /// Run the launch command as the initial remote command while still
        /// requesting a PTY, matching `ssh -t host command`.
        case initialCommandWithPTY

        var displayName: String {
            switch self {
            case .afterConnect:
                return String(localized: "Send after connect", comment: "Launch command mode")
            case .initialCommandWithPTY:
                return String(localized: "Run as initial command", comment: "Launch command mode")
            }
        }
    }

    /// Tool locations for non-interactive SSH exec requests. See
    /// `RemoteLoginShell` (dependency-free, symlinked into the SwiftPM test
    /// package) for the entries and the Darwin/autofs #391 reasoning.
    nonisolated static let remoteExecToolPathEntries = RemoteLoginShell.toolPathEntries

    /// Linux-only tool locations. See `RemoteLoginShell.linuxPathEntries`.
    nonisolated static let remoteExecLinuxPathEntries = RemoteLoginShell.linuxPathEntries

    nonisolated static let remoteExecSystemPathEntries = RemoteLoginShell.systemPathEntries

    /// Shell snippet that prepends the entries above that exist on the target,
    /// in order, preserving its existing PATH. See `RemoteLoginShell.pathPrefix`.
    nonisolated static let remoteExecPathPrefix = RemoteLoginShell.pathPrefix

    /// The hostname or IP address to connect to
    var host: String

    /// The port to connect to (default: 22)
    var port: Int = 22

    /// The username for authentication
    var username: String

    /// The authentication method to use
    var authMethod: AuthMethod = .password("")

    /// Cached resolved IP for .local hostnames (VPN fallback)
    var cachedIP: String? = nil

    /// Optional jump host configuration for ProxyJump-style connections
    var jumpHost: JumpHostConfig? = nil

    /// HSS shorthand that was used to create this config (for history tracking)
    var hssShorthand: String? = nil

    /// Cloud instance label (for display in tab name when connected via cloud autocomplete)
    var cloudInstanceLabel: String? = nil

    /// SSH agent forwarding configuration
    var agentConfig: SSHAgentConfig = .disabled

    /// GPG agent forwarding configuration. Defaults to disabled so
    /// existing profiles decode unchanged.
    var gpgAgentConfig: GPGAgentConfig = .disabled

    /// SSH port forwarding configuration
    var portForwardConfig: PortForwardConfig = .none

    /// Whether to automatically start/attach to a tmux session on connect
    var tmuxAutoEnable: Bool = false

    /// Which tmux flavor to launch when `tmuxAutoEnable` is true. Kept separate
    /// from the bool so older app versions that only know `tmuxAutoEnable` still
    /// auto-start a regular session (the unknown mode key is ignored).
    var tmuxAutoMode: TmuxAutoMode = .regular

    /// Whether to automatically attach to (or create) a herdr session on
    /// connect. Mutually exclusive with `tmuxAutoEnable` in the UI; when both
    /// are somehow set, tmux wins.
    var herdrAutoEnable: Bool = false
    var zmxAutoEnable: Bool = false

    /// Session name for whichever multiplexer the auto-start picker selects.
    /// nil or empty falls back to the global default, which is how every
    /// existing profile decodes.
    var multiplexerSessionName: String? = nil

    /// Command to run when the session starts. The mode controls whether this is
    /// sent as terminal input or used as the initial PTY exec command.
    var launchCommand: String? = nil

    /// How the launch command should be applied.
    var launchCommandMode: LaunchCommandMode = .afterConnect

    /// Per-connection `TERM` override. nil inherits the global remote default
    /// from Settings, so existing profiles are unaffected.
    var terminalType: String? = nil

    /// Additional keys to try if primary key fails (from default keys list)
    /// These are tried in order after the primary authMethod key
    var fallbackKeyIDs: [UUID]? = nil

    /// Resolution hints for cross-device key matching (keyed by UUID string)
    /// Populated when saving profiles or recording successful connections.
    /// nil for backward compat — old profiles decode fine without it.
    var keyResolutionHints: [String: KeyResolutionHint]? = nil

    /// Remote command to execute via SSH exec request instead of interactive shell.
    /// Not persisted — remote commands are one-off from CLI parsing.
    /// Takes precedence over tmuxAutoEnable.
    var remoteCommand: String? = nil

    /// Controls how `remoteCommand` is emitted over SSH exec.
    /// Not persisted — this is chosen by the call site at runtime.
    var remoteCommandPolicy: RemoteCommandPolicy = .verbatim

    /// Tracks if the password was loaded from Keychain (for history recording)
    /// Not persisted - only used at runtime to determine auth type for connection history
    var usedSavedPassword: Bool = false

    /// Tracks if the jump host password was loaded from Keychain (for history recording)
    /// Not persisted - only used at runtime to determine auth type for connection history
    var usedSavedJumpPassword: Bool = false

    /// Authentication method for SSH
    enum AuthMethod: Codable, Hashable {
        case password(String)  // Password authentication (password provided inline)
        case savedPassword     // Password stored in Keychain (lookup by connection key)
        case key(UUID)         // SSH key authentication (key ID)
        case none              // No authentication (Tailscale/WireGuard pre-authenticated)
        case keyboardInteractive   // Keyboard-interactive (RFC 4256): server-driven prompts (OTP/2FA/PAM)
        /// An auth method written by a newer app version that this build does not
        /// recognise. Preserved verbatim so a synced profile is neither dropped nor
        /// lossily rewritten. Not connectable on this version.
        case unknown(rawType: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case keyID
        }

        private enum MethodType: String, Codable {
            case password
            case savedPassword
            case key
            case none
            case keyboardInteractive
        }

        private enum LegacyCodingKeys: String, CodingKey {
            case password
            case savedPassword
            case key
            case none
        }

        private enum LegacyAssociatedValueKeys: String, CodingKey {
            case _0
        }

        var isPassword: Bool {
            if case .password = self { return true }
            return false
        }

        var isSavedPassword: Bool {
            if case .savedPassword = self { return true }
            return false
        }

        var isKey: Bool {
            if case .key = self { return true }
            return false
        }

        var isNone: Bool {
            if case .none = self { return true }
            return false
        }

        var isKeyboardInteractive: Bool {
            if case .keyboardInteractive = self { return true }
            return false
        }

        /// True for an auth method written by a newer app version that this build
        /// cannot use. Such connections should not be attempted.
        var isUnknown: Bool {
            if case .unknown = self { return true }
            return false
        }

        /// Returns true if this auth method uses password (either inline or saved)
        var usesPassword: Bool {
            switch self {
            case .password, .savedPassword:
                return true
            default:
                return false
            }
        }

        var keyID: UUID? {
            if case .key(let id) = self { return id }
            return nil
        }

        var password: String? {
            if case .password(let pwd) = self { return pwd }
            return nil
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let typeString = try? container.decode(String.self, forKey: .type) {
                // Decode the discriminator as a raw string (not MethodType) so an
                // auth type written by a newer app version maps to `.unknown`
                // instead of throwing — which would otherwise drop the whole
                // synced profile on this (older) build. See AuthMethod.unknown.
                guard let method = MethodType(rawValue: typeString) else {
                    self = .unknown(rawType: typeString)
                    return
                }
                switch method {
                case .password:
                    self = .password("")
                case .savedPassword:
                    self = .savedPassword
                case .key:
                    let keyID = try container.decode(UUID.self, forKey: .keyID)
                    self = .key(keyID)
                case .none:
                    self = .none
                case .keyboardInteractive:
                    self = .keyboardInteractive
                }
                return
            }

            let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if container.contains(.password) {
                if let nested = try? container.nestedContainer(keyedBy: LegacyAssociatedValueKeys.self, forKey: .password),
                   let password = try? nested.decode(String.self, forKey: ._0) {
                    self = .password(password)
                } else {
                    self = .password("")
                }
                return
            }
            if container.contains(.savedPassword) {
                self = .savedPassword
                return
            }
            if container.contains(.key) {
                let nested = try container.nestedContainer(keyedBy: LegacyAssociatedValueKeys.self, forKey: .key)
                let keyID = try nested.decode(UUID.self, forKey: ._0)
                self = .key(keyID)
                return
            }
            if container.contains(.none) {
                self = .none
                return
            }

            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported SSH auth method payload")
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .password:
                // Password values are never persisted to JSON.
                try container.encode(MethodType.password, forKey: .type)
            case .savedPassword:
                try container.encode(MethodType.savedPassword, forKey: .type)
            case .key(let keyID):
                try container.encode(MethodType.key, forKey: .type)
                try container.encode(keyID, forKey: .keyID)
            case .none:
                try container.encode(MethodType.none, forKey: .type)
            case .keyboardInteractive:
                try container.encode(MethodType.keyboardInteractive, forKey: .type)
            case .unknown(let rawType):
                // Re-emit the original discriminator verbatim so round-tripping
                // through this version does not corrupt the synced value.
                try container.encode(rawType, forKey: .type)
            }
        }
    }

    /// Configuration for an SSH jump host (bastion/proxy)
    struct JumpHostConfig: Codable, Hashable {
        /// The hostname or IP address of the jump host
        var host: String

        /// The port to connect to (default: 22)
        var port: Int = 22

        /// The username for authentication on the jump host
        var username: String

        /// The authentication method for the jump host
        var authMethod: AuthMethod

        /// Additional keys to try if primary key fails (from default keys list)
        var fallbackKeyIDs: [UUID]? = nil

        /// Resolution hints for cross-device key matching (keyed by UUID string)
        var keyResolutionHints: [String: KeyResolutionHint]? = nil

        // MARK: - Codable (backward-compatible)

        private enum CodingKeys: String, CodingKey {
            case host, port, username, authMethod, fallbackKeyIDs, keyResolutionHints
        }

        init(host: String, port: Int = 22, username: String, authMethod: AuthMethod, fallbackKeyIDs: [UUID]? = nil, keyResolutionHints: [String: KeyResolutionHint]? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.authMethod = authMethod
            self.fallbackKeyIDs = fallbackKeyIDs
            self.keyResolutionHints = keyResolutionHints
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            host = try container.decode(String.self, forKey: .host)
            port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
            username = try container.decode(String.self, forKey: .username)
            authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
            fallbackKeyIDs = try container.decodeIfPresent([UUID].self, forKey: .fallbackKeyIDs)
            keyResolutionHints = try container.decodeIfPresent([String: KeyResolutionHint].self, forKey: .keyResolutionHints)
        }

        /// Display name for the jump host
        var displayName: String {
            port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
        }

        /// Validate the jump host configuration
        var isValid: Bool {
            let basicValid = !host.isEmpty && !username.isEmpty && port > 0 && port <= 65535

            switch authMethod {
            case .password(let pwd):
                return basicValid && !pwd.isEmpty
            case .savedPassword:
                // Valid if we have a saved password for this jump host
                return basicValid && SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username)
            case .key(let keyID):
                // Use hint-enhanced resolution for cross-device key support
                let hint = keyResolutionHints?[keyID.uuidString]
                return basicValid && SSHKeyManager.shared.resolveKey(id: keyID, hint: hint) != nil
            case .none:
                return basicValid  // No additional auth validation needed for none
            case .keyboardInteractive:
                return basicValid  // Server drives the prompts; no stored credential required
            case .unknown:
                return false       // Auth method from a newer app version; not usable here
            }
        }
    }

    /// Whether this connection uses a jump host
    var usesJumpHost: Bool {
        jumpHost != nil
    }

    /// Whether this config uses a saved password (looks up from Keychain)
    var usesSavedPassword: Bool {
        authMethod.isSavedPassword
    }

    /// Connection key for password lookup (format: "host:port:username")
    var connectionKey: String {
        SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)
    }

    /// Resolves the auth method by loading saved password if needed
    /// - Returns: A copy of this config with password resolved from Keychain
    /// - Throws: If saved password cannot be loaded
    @MainActor
    func resolvedConfig() async throws -> SSHConfig {
        var resolved = self

        // Resolve target auth
        if case .savedPassword = authMethod {
            let password = try await SSHPasswordManager.shared.loadPassword(
                host: host,
                port: port,
                username: username
            )
            resolved.authMethod = .password(password)
            resolved.usedSavedPassword = true
        }

        // Resolve jump host auth if needed
        if var jumpConfig = resolved.jumpHost, case .savedPassword = jumpConfig.authMethod {
            let jumpPassword = try await SSHPasswordManager.shared.loadPassword(
                host: jumpConfig.host,
                port: jumpConfig.port,
                username: jumpConfig.username
            )
            jumpConfig.authMethod = .password(jumpPassword)
            resolved.jumpHost = jumpConfig
            resolved.usedSavedJumpPassword = true
        }

        return resolved
    }

    /// Legacy password property for backward compatibility
    @available(*, deprecated, message: "Use authMethod instead")
    var password: String {
        get {
            if case .password(let pwd) = authMethod {
                return pwd
            }
            return ""
        }
        set {
            authMethod = .password(newValue)
        }
    }

    /// Display name for the connection (derived from host and username)
    var displayName: String {
        // If we have a cloud instance label, show it prominently
        if let label = cloudInstanceLabel {
            if let jump = jumpHost {
                return "\(label) (\(username)@\(host)) via \(jump.displayName)"
            }
            return "\(label) (\(username)@\(host))"
        }

        if let jump = jumpHost {
            return "\(username)@\(host) via \(jump.displayName)"
        }
        return "\(username)@\(host)"
    }

    /// Validate the configuration
    var isValid: Bool {
        let basicValid = !host.isEmpty && !username.isEmpty && port > 0 && port <= 65535

        // Validate target auth method
        let targetAuthValid: Bool
        switch authMethod {
        case .password(let pwd):
            targetAuthValid = basicValid && !pwd.isEmpty
        case .savedPassword:
            // Valid if we have a saved password for this connection
            targetAuthValid = basicValid && SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username)
        case .key(let keyID):
            // Use hint-enhanced resolution for cross-device key support
            let hint = keyResolutionHints?[keyID.uuidString]
            targetAuthValid = basicValid && SSHKeyManager.shared.resolveKey(id: keyID, hint: hint) != nil
        case .none:
            targetAuthValid = basicValid  // No additional auth validation needed for none
        case .keyboardInteractive:
            targetAuthValid = basicValid  // Server drives the prompts; no stored credential required
        case .unknown:
            targetAuthValid = false       // Auth method from a newer app version; not usable here
        }

        // If using jump host, also validate jump host config
        if let jumpConfig = jumpHost {
            return targetAuthValid && jumpConfig.isValid
        }

        return targetAuthValid
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case host, port, username, authMethod, cachedIP, jumpHost
        case hssShorthand, cloudInstanceLabel, agentConfig, gpgAgentConfig, portForwardConfig
        case tmuxAutoEnable, tmuxAutoMode, herdrAutoEnable, zmxAutoEnable, launchCommand, launchCommandMode, fallbackKeyIDs, keyResolutionHints
        case terminalType, multiplexerSessionName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password("")
        cachedIP = try container.decodeIfPresent(String.self, forKey: .cachedIP)
        jumpHost = try container.decodeIfPresent(JumpHostConfig.self, forKey: .jumpHost)
        hssShorthand = try container.decodeIfPresent(String.self, forKey: .hssShorthand)
        cloudInstanceLabel = try container.decodeIfPresent(String.self, forKey: .cloudInstanceLabel)
        agentConfig = try container.decodeIfPresent(SSHAgentConfig.self, forKey: .agentConfig) ?? .disabled
        gpgAgentConfig = try container.decodeIfPresent(GPGAgentConfig.self, forKey: .gpgAgentConfig) ?? .disabled
        portForwardConfig = try container.decodeIfPresent(PortForwardConfig.self, forKey: .portForwardConfig) ?? .none
        tmuxAutoEnable = try container.decodeIfPresent(Bool.self, forKey: .tmuxAutoEnable) ?? false
        tmuxAutoMode = try container.decodeIfPresent(TmuxAutoMode.self, forKey: .tmuxAutoMode) ?? .regular
        herdrAutoEnable = try container.decodeIfPresent(Bool.self, forKey: .herdrAutoEnable) ?? false
        zmxAutoEnable = try container.decodeIfPresent(Bool.self, forKey: .zmxAutoEnable) ?? false
        launchCommand = try container.decodeIfPresent(String.self, forKey: .launchCommand)
        launchCommandMode = try container.decodeIfPresent(LaunchCommandMode.self, forKey: .launchCommandMode) ?? .afterConnect
        fallbackKeyIDs = try container.decodeIfPresent([UUID].self, forKey: .fallbackKeyIDs)
        keyResolutionHints = try container.decodeIfPresent([String: KeyResolutionHint].self, forKey: .keyResolutionHints)
        terminalType = try container.decodeIfPresent(String.self, forKey: .terminalType)
        multiplexerSessionName = try container.decodeIfPresent(String.self, forKey: .multiplexerSessionName)
    }

    /// Creates a new SSH configuration with password authentication
    init(host: String, port: Int = 22, username: String, password: String = "", cachedIP: String? = nil, jumpHost: JumpHostConfig? = nil, hssShorthand: String? = nil, cloudInstanceLabel: String? = nil, agentConfig: SSHAgentConfig = .disabled, portForwardConfig: PortForwardConfig = .none, tmuxAutoEnable: Bool = false, tmuxAutoMode: TmuxAutoMode = .regular, launchCommand: String? = nil, launchCommandMode: LaunchCommandMode = .afterConnect) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = .password(password)
        self.cachedIP = cachedIP
        self.jumpHost = jumpHost
        self.hssShorthand = hssShorthand
        self.cloudInstanceLabel = cloudInstanceLabel
        self.agentConfig = agentConfig
        self.portForwardConfig = portForwardConfig
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
        self.launchCommand = launchCommand
        self.launchCommandMode = launchCommandMode
    }

    /// Creates a new SSH configuration with key authentication
    /// - Parameters:
    ///   - fallbackKeyIDs: Additional keys to try if primary key fails (from default keys list)
    init(host: String, port: Int = 22, username: String, keyID: UUID, fallbackKeyIDs: [UUID]? = nil, cachedIP: String? = nil, jumpHost: JumpHostConfig? = nil, hssShorthand: String? = nil, cloudInstanceLabel: String? = nil, agentConfig: SSHAgentConfig = .disabled, portForwardConfig: PortForwardConfig = .none, tmuxAutoEnable: Bool = false, tmuxAutoMode: TmuxAutoMode = .regular, launchCommand: String? = nil, launchCommandMode: LaunchCommandMode = .afterConnect) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = .key(keyID)
        self.fallbackKeyIDs = fallbackKeyIDs
        self.cachedIP = cachedIP
        self.jumpHost = jumpHost
        self.hssShorthand = hssShorthand
        self.cloudInstanceLabel = cloudInstanceLabel
        self.agentConfig = agentConfig
        self.portForwardConfig = portForwardConfig
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
        self.launchCommand = launchCommand
        self.launchCommandMode = launchCommandMode
    }

    /// Creates a new SSH configuration with no authentication (Tailscale/WireGuard pre-authenticated)
    init(host: String, port: Int = 22, username: String, authMethod: AuthMethod = .none, cachedIP: String? = nil, jumpHost: JumpHostConfig? = nil, hssShorthand: String? = nil, cloudInstanceLabel: String? = nil, agentConfig: SSHAgentConfig = .disabled, portForwardConfig: PortForwardConfig = .none, tmuxAutoEnable: Bool = false, tmuxAutoMode: TmuxAutoMode = .regular, launchCommand: String? = nil, launchCommandMode: LaunchCommandMode = .afterConnect) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.cachedIP = cachedIP
        self.jumpHost = jumpHost
        self.hssShorthand = hssShorthand
        self.cloudInstanceLabel = cloudInstanceLabel
        self.agentConfig = agentConfig
        self.portForwardConfig = portForwardConfig
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
        self.launchCommand = launchCommand
        self.launchCommandMode = launchCommandMode
    }

    /// Shared tmux exec command used by all session types (SSH, Citadel, Trzsz, Mosh).
    /// Extends PATH for common install locations, attaches to the configured session or creates it,
    /// falls back to $SHELL if tmux is not installed.
    /// Reads "tmuxCustomCommand" and "tmuxSessionName" from UserDefaults.
    static var tmuxExecCommand: String {
        if let custom = tmuxGlobalCustomCommand {
            return custom
        }
        return tmuxExecCommandLine(sessionName: tmuxGlobalSessionName, controlMode: false)
    }

    /// Non-empty "tmuxCustomCommand" setting, else nil.
    static var tmuxGlobalCustomCommand: String? {
        let custom = SettingsStore.shared.value(Settings.Multiplexer.tmuxCustomCommand)
        return custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : custom
    }

    /// Non-empty "herdrCustomCommand" setting, else nil.
    static var herdrGlobalCustomCommand: String? {
        let custom = SettingsStore.shared.value(Settings.Multiplexer.herdrCustomCommand)
        return custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : custom
    }

    /// Globally-configured default tmux session name ("main" when unset).
    static var tmuxGlobalSessionName: String {
        let name = SettingsStore.shared.value(Settings.Multiplexer.tmuxSessionName)
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "main"
    }

    /// Builds the `sh -c '...'` line that attaches to (or creates) a tmux
    /// session, optionally in control mode (`-CC`), falling back to `$SHELL`
    /// when tmux is missing. The session name must already be validated as
    /// embeddable in the single-quoted command (see TmuxGatewaySessionStore).
    static func tmuxExecCommandLine(sessionName: String, controlMode: Bool) -> String {
        let cc = controlMode ? "-CC " : ""
        return "sh -c '\(remoteExecPathPrefix)command -v tmux >/dev/null && exec tmux \(cc)new-session -A -s \(sessionName) || exec $SHELL'"
    }

    /// Session name to attach to for this connection. The profile's explicit
    /// override wins, since declared intent outranks the inferred last-attached
    /// memory; then the session the user was last attached to ON THIS
    /// CONNECTION (recorded by the tmux session dashboard on
    /// attach/switch/rename, and only ever an embeddable name — see
    /// TmuxGatewaySessionStore); then the global default.
    var tmuxSessionNameForConnection: String {
        if let override = multiplexerSessionNameOverride,
           TmuxControlModeParser.isEmbeddableSessionName(override) {
            return override
        }
        let key = TmuxGatewaySessionStore.connectionKey(host: host, port: port, username: username)
        if let name = TmuxGatewaySessionStore.lastSessionName(forConnection: key),
           TmuxControlModeParser.isEmbeddableSessionName(name) {
            return name
        }
        return Self.tmuxGlobalSessionName
    }

    /// `TERM` to advertise for this connection: the profile's override when set,
    /// otherwise the global remote default from Settings.
    var effectiveTerminalType: String {
        TerminalTypeSettings.resolveRemote(terminalType)
    }

    /// Per-connection variant of `tmuxExecCommand`: uses the per-connection
    /// session name and the connection's `tmuxAutoMode` (regular vs `-CC`
    /// control mode). A custom "tmuxCustomCommand" still wins.
    var tmuxExecCommandForConnection: String {
        if let custom = Self.tmuxGlobalCustomCommand {
            return custom
        }
        return Self.tmuxExecCommandLine(sessionName: tmuxSessionNameForConnection,
                                        controlMode: tmuxAutoMode == .control)
    }

    /// Globally-configured herdr session name. Empty means the default
    /// (unnamed) session — bare `herdr` with no `--session` flag.
    static var herdrGlobalSessionName: String {
        SettingsStore.shared.value(Settings.Multiplexer.herdrSessionName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isEmbeddableHerdrSessionName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 64 && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
    }

    /// The profile's session-name override, trimmed, or nil when unset. Which
    /// multiplexer it applies to is decided by the auto-start picker, never by
    /// the value.
    var multiplexerSessionNameOverride: String? {
        guard let name = multiplexerSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    static func isEmbeddableMultiplexerSessionName(_ name: String) -> Bool {
        isEmbeddableHerdrSessionName(name)
    }

    static func isEmbeddableZmxSessionName(_ name: String) -> Bool {
        isEmbeddableMultiplexerSessionName(name) && !name.hasPrefix("-")
    }

    /// Builds the `sh -c '...'` line that attaches to (or creates) a herdr
    /// session, falling back to `$SHELL` when herdr is missing. herdr's bare
    /// launch is attach-or-create, so no `-A` analogue is needed.
    static func herdrExecCommandLine(sessionName: String) -> String {
        let arg = isEmbeddableHerdrSessionName(sessionName) ? " --session \(sessionName)" : ""
        return "sh -c '\(remoteExecPathPrefix)command -v herdr >/dev/null && exec herdr\(arg) || exec $SHELL'"
    }

    /// Shared herdr exec command used by all session types.
    /// Reads "herdrCustomCommand" and "herdrSessionName" from UserDefaults.
    static var herdrExecCommand: String {
        if let custom = herdrGlobalCustomCommand {
            return custom
        }
        return herdrExecCommandLine(sessionName: herdrGlobalSessionName)
    }

    /// Session name herdr auto-attach targets, for display and for the
    /// raw-multiplexer binding. "default" is herdr's literal name for the
    /// unnamed default session.
    static var herdrEffectiveSessionName: String {
        let name = herdrGlobalSessionName
        return isEmbeddableHerdrSessionName(name) ? name : "default"
    }

    /// Raw name handed to the exec builder: profile override, else global. An
    /// empty string stays empty on purpose - that is what makes the command a
    /// bare `herdr` attaching to herdr's own unnamed session. Never substitute
    /// "default" here; that is a display label, not a session name.
    var herdrRawSessionNameForConnection: String {
        multiplexerSessionNameOverride ?? Self.herdrGlobalSessionName
    }

    var herdrSessionNameForConnection: String {
        let raw = herdrRawSessionNameForConnection
        return Self.isEmbeddableHerdrSessionName(raw) ? raw : "default"
    }

    /// Per-connection variant of `herdrExecCommand`. A custom
    /// "herdrCustomCommand" still wins.
    var herdrExecCommandForConnection: String {
        if let custom = Self.herdrGlobalCustomCommand {
            return custom
        }
        return Self.herdrExecCommandLine(sessionName: herdrRawSessionNameForConnection)
    }

    // MARK: - zmx auto-start

    /// zmx has no default-session concept: `zmx attach` with no name is an
    /// error, so unlike herdr the fallback has to be a real name.
    static let zmxDefaultSessionName = "main"

    /// Globally-configured zmx session name, falling back to `main`.
    static var zmxGlobalSessionName: String {
        let raw = SettingsStore.shared.value(Settings.Multiplexer.zmxSessionName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? zmxDefaultSessionName : raw
    }

    /// Globally-configured zmx custom command, nil when empty.
    static var zmxGlobalCustomCommand: String? {
        let custom = SettingsStore.shared.value(Settings.Multiplexer.zmxCustomCommand)
        return custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : custom
    }

    /// Builds the attach-or-create command, falling back to `$SHELL`.
    static func zmxExecCommandLine(sessionName: String) -> String {
        let name = isEmbeddableZmxSessionName(sessionName) ? sessionName : zmxDefaultSessionName
        // Listed names already contain any configured session prefix.
        return "sh -c '\(remoteExecPathPrefix)command -v zmx >/dev/null"
            + " && ZMX_SESSION_PREFIX= exec zmx attach \(name)"
            + " || exec $SHELL'"
    }

    /// Shared zmx exec command used by all session types.
    static var zmxExecCommand: String {
        if let custom = zmxGlobalCustomCommand {
            return custom
        }
        return zmxExecCommandLine(sessionName: zmxGlobalSessionName)
    }

    /// The auto-start session, or nil when a custom command makes it unknowable.
    var zmxSessionNameForConnection: String? {
        if Self.zmxGlobalCustomCommand != nil {
            return nil
        }
        let raw = multiplexerSessionNameOverride ?? Self.zmxGlobalSessionName
        return Self.isEmbeddableZmxSessionName(raw) ? raw : Self.zmxDefaultSessionName
    }

    /// Per-connection variant of `zmxExecCommand`. A custom "zmxCustomCommand"
    /// still wins.
    var zmxExecCommandForConnection: String {
        if let custom = Self.zmxGlobalCustomCommand {
            return custom
        }
        return Self.zmxExecCommandLine(sessionName: multiplexerSessionNameOverride ?? Self.zmxGlobalSessionName)
    }

    /// Session name the given picker selection would attach to, for the editor
    /// captions. Deliberately ignores TmuxGatewaySessionStore: the editor may
    /// describe a profile with no live connection, and the captions already
    /// showed the global before this override existed.
    static func multiplexerSessionDisplayName(for selection: TmuxLaunchSelection,
                                              override: String?) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pinned = trimmed.isEmpty ? nil : trimmed
        switch selection {
        case .off:
            return ""
        case .regular, .control:
            if tmuxGlobalCustomCommand != nil {
                return "custom"
            }
            if let pinned, TmuxControlModeParser.isEmbeddableSessionName(pinned) {
                return pinned
            }
            return tmuxGlobalSessionName
        case .herdr:
            if herdrGlobalCustomCommand != nil {
                return "custom"
            }
            let raw = pinned ?? herdrGlobalSessionName
            return isEmbeddableHerdrSessionName(raw) ? raw : "default"
        case .zmx:
            if zmxGlobalCustomCommand != nil {
                return "custom"
            }
            let raw = pinned ?? zmxGlobalSessionName
            return isEmbeddableZmxSessionName(raw) ? raw : zmxDefaultSessionName
        }
    }

    static func command(_ command: String, applying policy: RemoteCommandPolicy) -> String {
        switch policy {
        case .verbatim:
            return command
        case .prependPATH:
            return remoteExecPathPrefix + command
        }
    }

    static func shellSingleQuote(_ string: String) -> String { RemoteLoginShell.singleQuoted(string) }

    var initialLaunchCommand: String? {
        guard launchCommandMode == .initialCommandWithPTY,
              let launchCommand,
              !launchCommand.isEmpty else {
            return nil
        }
        return launchCommand
    }

    /// Whether the channel replaced the interactive shell with a command.
    var hasExecTakeoverCommand: Bool {
        !MuxDetachGate.hasFallbackShell(
            hasRemoteCommand: !(remoteCommand?.isEmpty ?? true),
            hasInitialCommandLaunch: initialLaunchCommand != nil,
            tmuxAutoEnable: tmuxAutoEnable,
            herdrAutoEnable: herdrAutoEnable,
            zmxAutoEnable: zmxAutoEnable
        )
    }

    /// Returns the exec command to use, if any.
    /// Remote command takes precedence over profile launch command and
    /// multiplexer auto-start; precedence among multiplexers is tmux, then
    /// herdr, then zmx.
    var effectiveExecCommand: String? {
        if let remoteCommand, !remoteCommand.isEmpty {
            return Self.command(remoteCommand, applying: remoteCommandPolicy)
        }
        if let initialLaunchCommand {
            return initialLaunchCommand
        }
        if tmuxAutoEnable {
            return tmuxExecCommandForConnection
        }
        if herdrAutoEnable {
            return herdrExecCommandForConnection
        }
        if zmxAutoEnable {
            return zmxExecCommandForConnection
        }
        return nil
    }

    /// Returns the command mosh-server should run inside the mosh session.
    var effectiveMoshSessionCommand: String {
        if let remoteCommand, !remoteCommand.isEmpty {
            return "sh -lc \(Self.shellSingleQuote(Self.command(remoteCommand, applying: remoteCommandPolicy)))"
        }
        if let initialLaunchCommand {
            return "sh -lc \(Self.shellSingleQuote(initialLaunchCommand))"
        }
        if tmuxAutoEnable {
            // Control mode (`-CC`) can't survive Mosh's state-sync transport, so
            // always launch a regular session here regardless of the stored mode.
            if let custom = Self.tmuxGlobalCustomCommand {
                return custom
            }
            return Self.tmuxExecCommandLine(sessionName: tmuxSessionNameForConnection, controlMode: false)
        }
        if herdrAutoEnable {
            // herdr has no control mode; the same exec line works under Mosh.
            return herdrExecCommandForConnection
        }
        if zmxAutoEnable {
            return zmxExecCommandForConnection
        }
        return "$SHELL -l"
    }
}
