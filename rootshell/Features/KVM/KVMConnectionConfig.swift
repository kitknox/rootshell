//
//  KVMConnectionConfig.swift
//  rootshell
//
//  Persistent configuration for a KVM over IP connection (GL.iNet Comet
//  and other kvmd devices).
//

import Foundation

/// MainActor like `VNCConnectionConfig`: `Jump.sshConfig` embeds `SSHConfig`,
/// whose Codable conformance is MainActor-isolated.
///
/// No password field: the device password is a Keychain lookup via
/// `VNCPasswordManager.kvm` keyed by `passwordKey`. Stream quality is a
/// device-wide setting, so it lives in the session HUD, not here.
struct KVMConnectionConfig: Codable, Hashable, Sendable {
    typealias Jump = VNCConnectionConfig.Jump
    typealias KeyboardToolbarPreference = VNCConnectionConfig.KeyboardToolbarPreference

    static let defaultPort = 443
    static let defaultUsername = "admin"

    var host: String
    var port: Int
    var username: String
    var jump: Jump
    var keyboardToolbar: KeyboardToolbarPreference
    var automaticallyEnterFullScreen: Bool
    /// kvmd keymap for the remote computer's keyboard layout. Text without a
    /// physical key (touch keyboard, dictation, paste) is typed with it.
    var hostKeyboardLayout: String
    /// Usually wanted for a Mac, which reverses a USB wheel with its own
    /// natural scrolling setting.
    var reverseScrolling: Bool

    init(
        host: String,
        port: Int = KVMConnectionConfig.defaultPort,
        username: String = KVMConnectionConfig.defaultUsername,
        jump: Jump = .none,
        keyboardToolbar: KeyboardToolbarPreference = .followAppSetting,
        automaticallyEnterFullScreen: Bool = false,
        hostKeyboardLayout: String = KVMInputTranslator.usLayout,
        reverseScrolling: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.jump = jump
        self.keyboardToolbar = keyboardToolbar
        self.automaticallyEnterFullScreen = automaticallyEnterFullScreen
        self.hostKeyboardLayout = hostKeyboardLayout
        self.reverseScrolling = reverseScrolling
    }

    // MARK: - Codable (lossy per field)

    private enum CodingKeys: String, CodingKey {
        case host, port, username, jump, keyboardToolbar
        case automaticallyEnterFullScreen, hostKeyboardLayout, reverseScrolling
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Synced as an opaque envelope: one field from another build must not
        // erase an otherwise usable configuration.
        host = ((try? container.decodeIfPresent(String.self, forKey: .host)) ?? nil) ?? ""
        port = ((try? container.decodeIfPresent(Int.self, forKey: .port)) ?? nil)
            ?? ((try? container.decodeIfPresent(String.self, forKey: .port)) ?? nil).flatMap(Int.init)
            ?? Self.defaultPort
        let user = ((try? container.decodeIfPresent(String.self, forKey: .username)) ?? nil) ?? ""
        username = user.isEmpty ? Self.defaultUsername : user
        jump = ((try? container.decodeIfPresent(Jump.self, forKey: .jump)) ?? nil) ?? .none
        keyboardToolbar = ((try? container.decodeIfPresent(String.self, forKey: .keyboardToolbar)) ?? nil)
            .flatMap(KeyboardToolbarPreference.init(rawValue:)) ?? .followAppSetting
        automaticallyEnterFullScreen = ((try? container.decodeIfPresent(Bool.self, forKey: .automaticallyEnterFullScreen)) ?? nil) ?? false
        let layout = ((try? container.decodeIfPresent(String.self, forKey: .hostKeyboardLayout)) ?? nil) ?? ""
        hostKeyboardLayout = layout.isEmpty ? KVMInputTranslator.usLayout : layout
        reverseScrolling = ((try? container.decodeIfPresent(Bool.self, forKey: .reverseScrolling)) ?? nil) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(jump, forKey: .jump)
        try container.encode(keyboardToolbar, forKey: .keyboardToolbar)
        try container.encode(automaticallyEnterFullScreen, forKey: .automaticallyEnterFullScreen)
        try container.encode(hostKeyboardLayout, forKey: .hostKeyboardLayout)
        try container.encode(reverseScrolling, forKey: .reverseScrolling)
    }

    // MARK: - Computed

    var displayName: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }

    var passwordKey: String {
        "kvm:\(username)@\(host):\(port)"
    }

    /// `https://host:port`, bracketing IPv6 literals.
    var baseURL: URL? {
        Self.baseURL(host: host, port: port)
    }

    static func baseURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port
        return components.url
    }
}

/// kvmd's bundled keymaps, by the names `/api/hid/print` accepts.
nonisolated enum KVMKeyboardLayouts {
    static let all: [String] = [
        "en-us", "en-gb", "en-us-altgr-intl", "ar", "bepo", "cz", "da", "de", "de-ch",
        "es", "et", "fi", "fo", "fr", "fr-be", "fr-ca", "fr-ch", "hr", "hu", "is", "it",
        "ja", "lt", "lv", "mk", "nl", "no", "pl", "pt", "pt-br", "ru", "sl", "sv", "th", "tr",
    ]

    static func displayName(_ keymap: String) -> String {
        switch keymap {
        case "bepo":
            return localizedName("fr") + " (BÉPO)"
        case "en-us-altgr-intl":
            return localizedName("en_US") + " (AltGr Intl)"
        case "cz":
            return localizedName("cs")
        default:
            return localizedName(keymap.replacingOccurrences(of: "-", with: "_").uppercasedRegion)
        }
    }

    private static func localizedName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

private extension String {
    /// "de_ch" → "de_CH", so Locale reads the region.
    nonisolated var uppercasedRegion: String {
        let parts = split(separator: "_")
        guard parts.count == 2 else { return self }
        return "\(parts[0])_\(parts[1].uppercased())"
    }
}
