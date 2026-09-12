//
//  VNCConnectionConfig.swift
//  rootshell
//
//  Persistent configuration for a Screen Sharing / VNC connection.
//

import Foundation

#if canImport(rootshellVNC)
import rootshellVNC
import RFBProtocol
#endif

/// App-side configuration for a VNC / Apple Screen Sharing connection.
///
/// Deliberately NOT `nonisolated`: the `Jump.sshConfig` payload embeds
/// `SSHConfig`, whose Codable/Hashable conformances are MainActor-isolated
/// under the project's default isolation, so this type stays MainActor too.
/// All persistence paths (ConnectionProfile, ProfileExtensionPayload) decode
/// on the main actor; window-state restoration goes through the nonisolated
/// `SerializableConnectionConfig.VNCConfigSafe` instead.
///
/// No password field, by design: the VNC password is a runtime Keychain
/// lookup via `VNCPasswordManager` keyed by `passwordKey`, so it can never
/// leak into profile JSON, CKRecords, or window state.
struct VNCConnectionConfig: Codable, Hashable, Sendable {

    /// Connection-mode / quality profile. Raw values match the package's
    /// `VNCConfiguration.VideoQualityMode` and are persisted.
    nonisolated enum QualityMode: String, Codable, CaseIterable, Hashable, Sendable {
        /// Apple High Performance (HEVC over UDP). Requires direct reachability.
        case adaptive
        /// Apple Standard (compressed RFB over TCP).
        case standard
        /// Lossless Zlib/ZRLE over TCP.
        case fullQuality

        var displayName: String {
            switch self {
            case .adaptive:
                return String(localized: "High Performance", comment: "VNC quality mode")
            case .standard:
                return String(localized: "Standard", comment: "VNC quality mode")
            case .fullQuality:
                return String(localized: "Full Quality", comment: "VNC quality mode")
            }
        }
    }

    /// Preferred RFB security type. `.automatic` lets the client negotiate
    /// the best type the server offers.
    nonisolated enum SecurityPreference: String, Codable, CaseIterable, Hashable, Sendable {
        case automatic
        case none
        case vncPassword
        case appleDH
        case appleARD

        var displayName: String {
            switch self {
            case .automatic:
                return String(localized: "Automatic", comment: "VNC security preference")
            case .none:
                return String(localized: "None", comment: "VNC security preference")
            case .vncPassword:
                return String(localized: "VNC Password", comment: "VNC security preference")
            case .appleDH:
                return String(localized: "Apple Diffie-Hellman", comment: "VNC security preference")
            case .appleARD:
                return String(localized: "Apple Remote Desktop", comment: "VNC security preference")
            }
        }
    }

    /// Per-connection override for the on-screen keyboard toolbar.
    nonisolated enum KeyboardToolbarPreference: String, Codable, CaseIterable, Hashable, Sendable {
        case followAppSetting
        case on
        case off
    }

    /// How the TCP transport reaches the server. Only Standard / Full Quality
    /// support jumping; High Performance requires direct UDP reachability.
    enum Jump: Codable, Hashable, Sendable {
        case none
        case sshProfile(UUID)
        case sshConfig(SSHConfig)
        case tsshProfile(UUID)

        private enum CodingKeys: String, CodingKey {
            case kind, profileID, sshConfig
        }

        /// Persisted discriminator. `direct` keeps the "none" raw value so
        /// the case name can't collide with `Optional.none` when matching.
        private enum Kind: String {
            case direct = "none"
            case sshProfile
            case sshConfig
            case tsshProfile
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kindRaw = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
            // Unknown discriminators (from a newer build) and missing/bad
            // payloads degrade to a direct connection, log-free.
            switch kindRaw.flatMap(Kind.init(rawValue:)) {
            case .sshProfile:
                if let id = (try? container.decodeIfPresent(UUID.self, forKey: .profileID)) ?? nil {
                    self = .sshProfile(id)
                } else {
                    self = .none
                }
            case .sshConfig:
                if let config = (try? container.decodeIfPresent(SSHConfig.self, forKey: .sshConfig)) ?? nil {
                    self = .sshConfig(config)
                } else {
                    self = .none
                }
            case .tsshProfile:
                if let id = (try? container.decodeIfPresent(UUID.self, forKey: .profileID)) ?? nil {
                    self = .tsshProfile(id)
                } else {
                    self = .none
                }
            case .direct, nil:
                self = .none
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .none:
                try container.encode(Kind.direct.rawValue, forKey: .kind)
            case .sshProfile(let id):
                try container.encode(Kind.sshProfile.rawValue, forKey: .kind)
                try container.encode(id, forKey: .profileID)
            case .sshConfig(let config):
                try container.encode(Kind.sshConfig.rawValue, forKey: .kind)
                try container.encode(config, forKey: .sshConfig)
            case .tsshProfile(let id):
                try container.encode(Kind.tsshProfile.rawValue, forKey: .kind)
                try container.encode(id, forKey: .profileID)
            }
        }
    }

    /// Hostname or IP address of the VNC server.
    var host: String

    /// TCP port (default 5900).
    var port: Int

    /// Optional username for Apple Remote Desktop style authentication.
    var username: String?

    /// Connection quality profile.
    var quality: QualityMode

    /// Preferred RFB security type.
    var security: SecurityPreference

    /// How the server sizes the remote framebuffer. Stored as the raw string
    /// of the package's `DisplaySizingMode` so persisted profiles are
    /// decoupled from package enum evolution. nil = package default.
    var displaySizingModeRaw: String?

    /// Requested display topology. Raw string of the package's `DisplayMode`.
    /// nil = package default.
    var displayModeRaw: String?

    /// Whether negotiated remote system audio should play on this device.
    var enableRemoteAudio: Bool

    /// Whether detecting a Mac Login Window or lock screen should offer to
    /// type the saved connection password after user confirmation.
    var promptForLoginPasswordAtLoginWindow: Bool

    /// Transport jump for the TCP quality modes.
    var jump: Jump

    /// Per-connection keyboard toolbar override.
    var keyboardToolbar: KeyboardToolbarPreference

    /// Whether the pane should enter the in-window full-screen takeover after
    /// its initial connection becomes operational.
    var automaticallyEnterFullScreen: Bool

    init(
        host: String,
        port: Int = 5900,
        username: String? = nil,
        quality: QualityMode = .adaptive,
        security: SecurityPreference = .automatic,
        displaySizingModeRaw: String? = nil,
        displayModeRaw: String? = nil,
        enableRemoteAudio: Bool = true,
        promptForLoginPasswordAtLoginWindow: Bool = true,
        jump: Jump = .none,
        keyboardToolbar: KeyboardToolbarPreference = .followAppSetting,
        automaticallyEnterFullScreen: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.quality = quality
        self.security = security
        self.displaySizingModeRaw = displaySizingModeRaw
        self.displayModeRaw = displayModeRaw
        self.enableRemoteAudio = enableRemoteAudio
        self.promptForLoginPasswordAtLoginWindow = promptForLoginPasswordAtLoginWindow
        self.jump = jump
        self.keyboardToolbar = keyboardToolbar
        self.automaticallyEnterFullScreen = automaticallyEnterFullScreen
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case host, port, username, quality, security
        case displaySizingModeRaw, displayModeRaw
        case enableRemoteAudio, promptForLoginPasswordAtLoginWindow
        case jump, keyboardToolbar
        case automaticallyEnterFullScreen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Profile extensions are synced as an opaque JSON envelope. Decode
        // every field independently so one field written by a newer or older
        // build cannot erase the otherwise usable connection configuration.
        host = Self.lossyString(in: container, forKey: .host) ?? ""
        port = Self.lossyInt(in: container, forKey: .port) ?? 5900
        username = Self.lossyString(in: container, forKey: .username)

        let qualityRaw = Self.lossyString(in: container, forKey: .quality)
        quality = qualityRaw.flatMap(QualityMode.init(rawValue:))
            ?? Self.legacyQuality(rawValue: qualityRaw)
            ?? .adaptive

        let securityRaw = Self.lossyString(in: container, forKey: .security)
        security = securityRaw.flatMap(SecurityPreference.init(rawValue:))
            ?? Self.legacySecurity(rawValue: securityRaw)
            ?? .automatic

        displaySizingModeRaw = Self.lossyString(in: container, forKey: .displaySizingModeRaw)
        displayModeRaw = Self.lossyString(in: container, forKey: .displayModeRaw)
        enableRemoteAudio = Self.lossyBool(
            in: container,
            forKey: .enableRemoteAudio) ?? true
        promptForLoginPasswordAtLoginWindow = Self.lossyBool(
            in: container,
            forKey: .promptForLoginPasswordAtLoginWindow) ?? true
        jump = ((try? container.decodeIfPresent(Jump.self, forKey: .jump)) ?? nil) ?? .none
        let toolbarRaw = Self.lossyString(in: container, forKey: .keyboardToolbar)
        keyboardToolbar = toolbarRaw.flatMap(KeyboardToolbarPreference.init(rawValue:))
            ?? .followAppSetting
        automaticallyEnterFullScreen = Self.lossyBool(
            in: container,
            forKey: .automaticallyEnterFullScreen) ?? false
    }

    private static func lossyString(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil {
            return String(value)
        }
        return nil
    }

    private static func lossyInt(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil {
            return Int(value)
        }
        return nil
    }

    private static func lossyBool(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil {
            return value != 0
        }
        guard let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil else {
            return nil
        }
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    private static func legacyQuality(rawValue: String?) -> QualityMode? {
        switch rawValue?.lowercased() {
        case "highperformance", "high_performance": return .adaptive
        case "lossless", "full_quality": return .fullQuality
        default: return nil
        }
    }

    private static func legacySecurity(rawValue: String?) -> SecurityPreference? {
        switch rawValue?.lowercased() {
        case "password", "vncauth", "vncauthentication": return .vncPassword
        case "apple30", "dh": return .appleDH
        case "macauthentication", "apple33", "ard": return .appleARD
        case "noauth": return SecurityPreference.none
        default: return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encode(quality, forKey: .quality)
        try container.encode(security, forKey: .security)
        try container.encodeIfPresent(displaySizingModeRaw, forKey: .displaySizingModeRaw)
        try container.encodeIfPresent(displayModeRaw, forKey: .displayModeRaw)
        try container.encode(enableRemoteAudio, forKey: .enableRemoteAudio)
        try container.encode(
            promptForLoginPasswordAtLoginWindow,
            forKey: .promptForLoginPasswordAtLoginWindow)
        try container.encode(jump, forKey: .jump)
        try container.encode(keyboardToolbar, forKey: .keyboardToolbar)
        try container.encode(automaticallyEnterFullScreen, forKey: .automaticallyEnterFullScreen)
    }

    // MARK: - Computed Properties

    /// Only the TCP quality modes can ride a tunnel; High Performance
    /// requires direct UDP reachability.
    var supportsJump: Bool {
        quality != .adaptive
    }

    /// Whether the destination uses a well-known mesh VPN DNS namespace.
    /// High Performance Screen Sharing's direct UDP transport tends to be
    /// less reliable over these overlay paths than Standard's TCP transport.
    var usesMeshVPNHostname: Bool {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        return ["ts.net", "netbird.cloud", "netbird.selfhosted"].contains { suffix in
            normalizedHost == suffix || normalizedHost.hasSuffix(".\(suffix)")
        }
    }

    /// The jump actually applied at connect time (High Performance forces direct).
    var effectiveJump: Jump {
        supportsJump ? jump : .none
    }

    /// Display string for tabs and suggestions ("user@host:port").
    var displayName: String {
        let hostPart = port == 5900 ? host : "\(host):\(port)"
        if let username, !username.isEmpty {
            return "\(username)@\(hostPart)"
        }
        return hostPart
    }

    /// Keychain account key for the saved password ("user@host:port").
    var passwordKey: String {
        "\(username ?? "")@\(host):\(port)"
    }
}

// MARK: - Package Mapping

// Behind canImport so this file compiles before the rootshellVNC package is
// linked into the app target (it lands in a later phase).
#if canImport(rootshellVNC)
extension VNCConnectionConfig {
    /// Map to the package configuration. A tunnel `transportProvider` is
    /// installed separately by the session launcher when a jump resolves;
    /// the package clamps `.adaptive` to `.standard` when one is set.
    func toPackageConfiguration() -> VNCConfiguration {
        var configuration = VNCConfiguration(
            videoQualityMode: VNCConfiguration.VideoQualityMode(rawValue: quality.rawValue) ?? .adaptive,
            securityPolicy: packageSecurityPolicy
        )
        if let raw = displaySizingModeRaw,
           let mode = VNCConfiguration.DisplaySizingMode(rawValue: raw) {
            configuration.displaySizingMode = mode
        }
        if let raw = displayModeRaw,
           let mode = VNCConfiguration.DisplayMode(rawValue: raw) {
            configuration.displayMode = mode
        }
        configuration.enableRemoteAudio = enableRemoteAudio
        configuration.promptForLoginPasswordAtLoginWindow =
            promptForLoginPasswordAtLoginWindow
        configuration.cursorRendering = Self.resolvedCursorRendering()
        return configuration
    }

    /// A device preference rather than a per-connection one, resolved here
    /// because this is the single place every package configuration is built.
    /// The session launcher rebuilds one from scratch at connect time and
    /// assigns it over the session's, so anything applied only at pane
    /// construction is silently discarded before the handshake.
    private static func resolvedCursorRendering() -> VNCCursorRendering {
        switch ScreenSharingCursorRenderingDefault.current {
        case .local:
            return .client
        case .remote:
            return .server
        }
    }

    private var packageSecurityPolicy: VNCConfiguration.SecurityPolicy {
        switch security {
        case .automatic: .automatic
        case .none: .none
        case .vncPassword: .vncAuthentication
        case .appleDH: .apple30
        case .appleARD: .macAuthentication
        }
    }

    /// Package credentials. The password comes from the Keychain at connect
    /// time; it is never stored on this struct.
    func toCredentials(password: String) -> VNCCredentials {
        VNCCredentials(
            host: host,
            port: UInt16(clamping: port),
            password: password,
            username: (username?.isEmpty == false) ? username : nil
        )
    }
}
#endif
