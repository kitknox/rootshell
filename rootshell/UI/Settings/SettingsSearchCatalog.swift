//
//  SettingsSearchCatalog.swift
//  rootshell
//
//  Settings search catalog. `SettingsSearchDestination` is the single source of
//  truth for every leaf screen; search entries are generated from it, so a new
//  case cannot ship without title, icon, section, availability, and view.
//

import SwiftUI

/// Every leaf screen reachable from Settings. Section rows push these by value.
enum SettingsSearchDestination: String, Hashable, CaseIterable {
    case appIcon
    case theme
    case font
    case cursor
    case appearanceMode
    case palette
    case backgroundEffect
    case customShaders
    case transparency
    case window
    case battery
    case visor
    case toolbarKeys
    case newTabAction
    case keyboardShortcuts
    case modTap
    case swipeGestures
    case promptAndUsername
    case bookmarkedLocations
    case locale
    case terminalType
    case localShell
    case ipGeolocation
    case sshKeys
    case gpgKeys
    case savedPasswords
    case knownHosts
    case hostCertificateAuthorities
    case sshShortcuts
    case localSSHAgent
    case externalSSHAgents
    case cloudProviders
    case wifiAPProviders
    case kubernetesClusters
    case backgroundTunnels
    case vpn
    case roam
    case screenSharing
    case sshTransport
    case multiplexers
    case codingAgents
    case taskDetection
    case pushNotifications
    case aiConfiguration
    case aiTextSize
    case mcpServer
    case voiceAgent
    case iCloudSync
    case backupRestore
    case syncedGroups
    case pinnedSettings
    case configFile
    case locationDiary
    case liveActivity
    case clipboardManager
    case autoRedact
    case acknowledgements
    case openSSHImport
    case ghosttyConfigImport
}

/// Compile-time facts, exposed as constants so availability reads as plain
/// boolean logic. The optimizer strips entries whose gate is a constant false.
private enum SearchBuild {
    static let isCatalyst = SettingsPlatform.isCatalyst
    static let isPhone = SettingsPlatform.isPhone
    #if os(visionOS)
    static let isVisionOS = true
    #else
    static let isVisionOS = false
    #endif
    #if STANDALONE
    static let isStandalone = true
    #else
    static let isStandalone = false
    #endif
    #if CHINA_BUILD
    static let isChinaBuild = true
    #else
    static let isChinaBuild = false
    #endif
    #if canImport(ActivityKit)
    static let hasActivityKit = true
    #else
    static let hasActivityKit = false
    #endif
    static var hasBrightnessBoost: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }
}

extension SettingsSearchDestination {
    private struct Meta {
        let section: SettingsSection
        let title: String
        let systemImage: String
        let keywords: [String]
    }

    private var meta: Meta {
        switch self {
        case .appIcon:
            Meta(section: .appearance, title: String(localized: "App Icon"), systemImage: "app.badge",
                 keywords: ["icon", "alternate icon", "home screen", "colorway", "radical of the unknown"])
        case .theme:
            Meta(section: .appearance, title: String(localized: "Theme"), systemImage: "paintpalette",
                 keywords: ["colors", "terminal theme", "day", "night", "light", "dark", "match system"])
        case .font:
            Meta(section: .appearance, title: String(localized: "Font"), systemImage: "textformat",
                 keywords: ["typeface", "size", "ligatures"])
        case .cursor:
            Meta(section: .appearance, title: String(localized: "Cursor"), systemImage: "character.cursor.ibeam",
                 keywords: ["beam", "block", "underline"])
        case .appearanceMode:
            Meta(section: .appearance, title: String(localized: "Appearance Mode"), systemImage: "circle.lefthalf.filled",
                 keywords: ["light", "dark", "system"])
        case .palette:
            Meta(section: .appearance, title: String(localized: "Colors"), systemImage: "swatchpalette",
                 keywords: ["palette", "harmonious", "256", "generate", "colors"])
        case .backgroundEffect:
            Meta(section: .appearance, title: String(localized: "Background Effect"), systemImage: "sparkles",
                 keywords: ["effects", "wallpaper", "visuals", "aurora", "solar graph", "fireflies", "butterflies",
                            "jellyfish", "photo", "video", "ken burns", "theme tint", "intensity", "speed"])
        case .customShaders:
            Meta(section: .appearance, title: String(localized: "Custom Shaders"), systemImage: "cpu",
                 keywords: ["shader", "graphics", "metal"])
        case .transparency:
            Meta(section: .appearance, title: String(localized: "Transparency"), systemImage: "slider.horizontal.below.rectangle",
                 keywords: ["opacity", "blur", "glass"])
        case .window:
            Meta(section: .appearance, title: String(localized: "Window"), systemImage: "macwindow",
                 keywords: ["tab bar", "group menu", "project switcher", "layout", "display", "brightness", "hdr", "edr",
                            "boost", "dynamic range", "selection", "loupe", "magnifier", "native"])
        case .battery:
            Meta(section: .appearance, title: String(localized: "Battery"), systemImage: "battery.25percent",
                 keywords: ["power", "refresh", "fps", "hz", "thermal", "saver", "low power", "promotion",
                            "adaptive", "charging", "plugged", "power source", "battery power", "wall power"])
        case .visor:
            Meta(section: .appearance, title: String(localized: "Visor"), systemImage: "rectangle.topthird.inset.filled",
                 keywords: ["hotkey", "drop-down", "quake", "slide", "overlay", "global shortcut"])
        case .toolbarKeys:
            Meta(section: .terminal, title: String(localized: "Toolbar Keys"), systemImage: "keyboard",
                 keywords: ["toolbar", "custom keys"])
        case .newTabAction:
            Meta(section: .terminal, title: String(localized: "New Tab Action"), systemImage: "plus.rectangle.on.rectangle",
                 keywords: ["new tab", "local", "ssh", "tmux", "last connection", "default"])
        case .keyboardShortcuts:
            Meta(section: .terminal, title: String(localized: "Keyboard Shortcuts"), systemImage: "command",
                 keywords: ["keybinds", "hotkeys", "category", "keybind editor", "reset"])
        case .modTap:
            Meta(section: .terminal, title: String(localized: "Mod-Tap Keys"), systemImage: "hand.tap",
                 keywords: ["caps lock", "modifier", "tap hold", "escape", "rules", "threshold", "input source", "hold"])
        case .swipeGestures:
            Meta(section: .terminal, title: String(localized: "Swipe Gestures"), systemImage: "hand.draw",
                 keywords: ["swipe", "gesture", "left swipe", "right swipe", "app tabs", "tmux windows",
                            "tmux sessions", "zellij tabs", "navigation"])
        case .promptAndUsername:
            Meta(section: .terminal, title: String(localized: "Prompt & Username"), systemImage: "person.text.rectangle",
                 keywords: ["starship", "username", "shell prompt"])
        case .bookmarkedLocations:
            Meta(section: .terminal, title: String(localized: "Bookmarked Locations"), systemImage: "bookmark",
                 keywords: ["bookmarks", "locations", "paths"])
        case .locale:
            Meta(section: .terminal, title: String(localized: "Locale"), systemImage: "globe",
                 keywords: ["lang", "language", "environment", "automatic", "custom", "don't send"])
        case .terminalType:
            Meta(section: .terminal, title: String(localized: "Terminal Type"), systemImage: "character.cursor.ibeam",
                 keywords: ["term", "terminfo", "xterm", "xterm-ghostty", "xterm-256color", "environment",
                            "local shell", "remote sessions", "custom", "vt100"])
        case .localShell:
            Meta(section: .terminal, title: String(localized: "Local Shell"), systemImage: "apple.terminal",
                 keywords: ["shell", "zsh", "bash", "fish", "nushell", "nu", "command", "login shell"])
        case .ipGeolocation:
            Meta(section: .terminal, title: String(localized: "IP Geolocation"), systemImage: "location",
                 keywords: ["geo", "location provider", "ipinfo", "cymru", "dns", "public ip", "clear geo cache", "disabled"])
        case .sshKeys:
            Meta(section: .connections, title: String(localized: "SSH Keys"), systemImage: "key",
                 keywords: ["public key", "private key", "agent"])
        case .gpgKeys:
            Meta(section: .connections, title: String(localized: "GPG Keys"), systemImage: "lock.shield",
                 keywords: ["gpg", "pgp", "openpgp", "import", "signing", "git commit signing", "export"])
        case .savedPasswords:
            Meta(section: .connections, title: String(localized: "Saved Passwords"), systemImage: "lock",
                 keywords: ["credentials", "keychain"])
        case .knownHosts:
            Meta(section: .connections, title: String(localized: "Known Hosts"), systemImage: "checkmark.shield",
                 keywords: ["fingerprints", "host keys", "clear all", "search", "fingerprint"])
        case .hostCertificateAuthorities:
            Meta(section: .connections, title: String(localized: "Certificate Authorities"), systemImage: "checkmark.seal",
                 keywords: ["ca", "host certificate", "cert-authority", "openssh certificate", "trusted ca",
                            "signed host key", "add ca", "clear all"])
        case .sshShortcuts:
            Meta(section: .connections, title: String(localized: "SSH Shortcuts"), systemImage: "bolt.horizontal",
                 keywords: ["hss", "host shorthand", "patterns", "config file", "reload"])
        case .localSSHAgent:
            Meta(section: .connections, title: String(localized: "Local SSH Agent"), systemImage: "point.3.connected.trianglepath.dotted",
                 keywords: ["ssh-agent", "SSH_AUTH_SOCK", "socket", "forwarding", "agent"])
        case .externalSSHAgents:
            Meta(section: .connections, title: String(localized: "SSH Agents"), systemImage: "key.radiowaves.forward",
                 keywords: ["1password", "secretive", "socket", "discovered", "add agent", "import identities", "external agent"])
        case .cloudProviders:
            Meta(section: .connections, title: String(localized: "Cloud Providers"), systemImage: "cloud",
                 keywords: ["aws", "azure", "digitalocean", "linode", "add account", "accounts"])
        case .wifiAPProviders:
            Meta(section: .connections, title: String(localized: "WiFi AP Providers"), systemImage: "wifi.router",
                 keywords: ["wireless", "access point", "manual ap", "bssid", "vendor", "add account"])
        case .kubernetesClusters:
            Meta(section: .connections, title: String(localized: "Kubernetes Clusters"), systemImage: "helm",
                 keywords: ["k8s", "kubectl", "clusters", "kubeconfig", "node shell", "orphaned pods"])
        case .backgroundTunnels:
            Meta(section: .connections, title: String(localized: "Background Tunnels"), systemImage: "arrow.triangle.swap",
                 keywords: ["port forwarding", "tunnels", "stop all", "event history", "profiles", "local forward"])
        case .vpn:
            Meta(section: .connections, title: String(localized: "VPN"), systemImage: "network.badge.shield.half.filled",
                 keywords: ["networking", "tunnel", "wireguard", "disconnect", "dns servers", "route exclusions",
                            "split tunnel", "cidr", "debug"])
        case .roam:
            Meta(section: .connections, title: String(localized: "Roam"), systemImage: "antenna.radiowaves.left.and.right",
                 keywords: ["mobility", "handoff", "mosh"])
        case .screenSharing:
            Meta(section: .connections, title: String(localized: "Screen Sharing"), systemImage: "display.2",
                 keywords: ["vnc", "remote desktop", "clipboard", "panning", "pointer", "encryption", "tunnel"])
        case .sshTransport:
            Meta(section: .connections, title: String(localized: "SSH Transport"), systemImage: "shield.lefthalf.filled",
                 keywords: ["ssh", "transport", "health", "probe", "post-quantum", "kex"])
        case .multiplexers:
            Meta(section: .connections, title: String(localized: "Multiplexers"), systemImage: "rectangle.split.2x1",
                 keywords: ["session manager", "multiplexer", "tmux", "zellij"])
        case .codingAgents:
            Meta(section: .terminal, title: String(localized: "Coding Agents"), systemImage: "sparkles.rectangle.stack",
                 keywords: ["agent", "claude code", "codex", "copilot", "cursor", "opencode", "detect", "inbox", "attention", "badge"])
        case .taskDetection:
            Meta(section: .terminal, title: String(localized: "Command Detection"), systemImage: "clock.badge.checkmark",
                 keywords: ["command", "task", "long running", "sudo", "password", "prompt", "build", "test", "pytest",
                            "cargo", "terraform", "rsync", "transfer", "detect"])
        case .pushNotifications:
            Meta(section: .notifications, title: String(localized: "Push Notifications"), systemImage: "lock.shield",
                 keywords: ["push", "apns", "hook", "claude code", "codex", "remote", "encrypted", "pair", "background"])
        case .aiConfiguration:
            Meta(section: .aiAssistant, title: String(localized: "Configuration"), systemImage: "gearshape",
                 keywords: ["providers", "api key", "models"])
        case .aiTextSize:
            Meta(section: .aiAssistant, title: String(localized: "Text Size"), systemImage: "textformat.size",
                 keywords: ["font", "chat text"])
        case .mcpServer:
            Meta(section: .aiAssistant, title: String(localized: "MCP Server"), systemImage: "server.rack",
                 keywords: ["tools", "server", "integration"])
        case .voiceAgent:
            Meta(section: .aiAssistant, title: String(localized: "Voice Agent"), systemImage: "waveform",
                 keywords: ["voice", "gemini", "audio", "speech"])
        case .iCloudSync:
            Meta(section: .privacyData, title: String(localized: "iCloud Sync"), systemImage: "arrow.triangle.2.circlepath.icloud",
                 keywords: ["sync", "cloudkit", "backup"])
        case .backupRestore:
            Meta(section: .privacyData, title: String(localized: "Backup & Restore"), systemImage: "archivebox",
                 keywords: ["export", "import", "archive", "encrypted", "password", "categories", "transfer", "migrate"])
        case .syncedGroups:
            Meta(section: .privacyData, title: String(localized: "Synced Groups"), systemImage: "square.grid.2x2",
                 keywords: ["sync", "group", "groups", "icloud", "pin", "local", "device", "sync all groups", "keep all on this device"])
        case .pinnedSettings:
            Meta(section: .privacyData, title: String(localized: "Pinned Settings"), systemImage: "pin",
                 keywords: ["pin", "pinned", "local", "device", "sync", "icloud", "sync again", "always on this device"])
        case .configFile:
            Meta(section: .privacyData, title: String(localized: "Config File"), systemImage: "doc.text",
                 keywords: ["config", "dotfile", "text", "file", "ghostty", "rootshell.conf", "editor", "create", "edit",
                            "reload", "show in finder"])
        case .locationDiary:
            Meta(section: .privacyData, title: String(localized: "View Diary"), systemImage: "book",
                 keywords: ["entries", "location history"])
        case .liveActivity:
            Meta(section: .privacyData, title: String(localized: "Live Activity"), systemImage: "record.circle",
                 keywords: ["dynamic island", "activity"])
        case .clipboardManager:
            Meta(section: .privacyData, title: String(localized: "Clipboard Manager"), systemImage: "list.clipboard",
                 keywords: ["clipboard", "history", "copy", "paste", "transform", "base64", "jwt"])
        case .autoRedact:
            Meta(section: .privacyData, title: String(localized: "Auto-Redact"), systemImage: "eye.slash",
                 keywords: ["redact", "privacy", "pii", "mask", "hide", "email", "name", "screenshot", "recording", "sensitive"])
        case .acknowledgements:
            Meta(section: .about, title: String(localized: "Acknowledgements"), systemImage: "doc.text",
                 keywords: ["licenses", "credits"])
        case .openSSHImport:
            Meta(section: .privacyData, title: String(localized: "Import from OpenSSH"), systemImage: "key.horizontal",
                 keywords: ["ssh config", "ssh_config", "import", "migrate", ".ssh", "identityfile", "openssh", "hosts"])
        case .ghosttyConfigImport:
            Meta(section: .privacyData, title: String(localized: "Import from Ghostty Config"), systemImage: "square.and.arrow.down.on.square",
                 keywords: ["ghostty", "config", "import", "migrate", "theme", "font", "keybinds", "palette"])
        }
    }

    var section: SettingsSection { meta.section }
    var title: String { meta.title }
    var systemImage: String { meta.systemImage }
    var keywords: [String] { meta.keywords }

    var isSuggested: Bool {
        switch self {
        case .theme, .font, .keyboardShortcuts, .sshKeys: true
        default: false
        }
    }

    /// Mirrors the `#if` around the section row that pushes this screen.
    /// Unavailable destinations get no search entry, so the `EmptyView()`
    /// fallbacks in `settingsSearchDestinationView` are unreachable.
    var isAvailable: Bool {
        guard section.isAvailable else { return false }
        switch self {
        case .appIcon:
            return AppIconManager.isSupported
        case .transparency:
            return SearchBuild.isCatalyst
        case .toolbarKeys, .promptAndUsername, .bookmarkedLocations, .locationDiary:
            return !SearchBuild.isCatalyst
        case .liveActivity:
            return SearchBuild.hasActivityKit && !SearchBuild.isCatalyst
        case .visor:
            #if os(iOS) && !targetEnvironment(macCatalyst)
            return UIDevice.current.userInterfaceIdiom == .pad
            #else
            return SearchBuild.isStandalone && SearchBuild.isCatalyst
            #endif
        case .localShell, .localSSHAgent, .externalSSHAgents:
            return SearchBuild.isStandalone && SearchBuild.isCatalyst
        case .vpn:
            return !SearchBuild.isChinaBuild && (!SearchBuild.isCatalyst || SearchBuild.isStandalone)
        default:
            return true
        }
    }

    var searchEntry: SettingsSearchEntry {
        SettingsSearchEntry(
            id: rawValue,
            title: title,
            subtitle: section.title,
            systemImage: systemImage,
            action: .destination(self),
            keywords: keywords,
            isSuggested: isSuggested
        )
    }
}

extension SettingsSection {
    var isAvailable: Bool {
        switch self {
        case .aiAssistant: !SearchBuild.isChinaBuild
        default: true
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .appearance: ["theme", "font", "cursor", "window", "colors"]
        case .terminal: ["keyboard", "locale", "prompt", "sessions"]
        case .connections: ["ssh", "cloud", "vpn", "hosts", "tmux", "vnc", "screen sharing", "remote desktop"]
        case .aiAssistant: ["providers", "mcp", "agent", "text size"]
        case .privacyData: ["icloud", "location", "sync", "live activity"]
        case .notifications: ["sound", "bell", "reminders"]
        case .about: ["version", "acknowledgements", "licenses"]
        }
    }

    var searchEntry: SettingsSearchEntry {
        SettingsSearchEntry(
            id: "section-\(rawValue)",
            title: title,
            subtitle: String(localized: "Settings"),
            systemImage: icon,
            action: .section(self),
            keywords: searchKeywords,
            isSuggested: self != .privacyData && self != .notifications && self != .about
        )
    }
}

enum SettingsSearchAction: Hashable {
    case section(SettingsSection)
    case destination(SettingsSearchDestination)
}

struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let action: SettingsSearchAction
    let keywords: [String]
    let isSuggested: Bool
    /// Only consulted while building `all`.
    var isAvailable: Bool = true

    private var searchBlob: String {
        ([title, subtitle] + keywords)
            .joined(separator: " ")
            .localizedLowercase
    }

    func matchScore(for rawQuery: String) -> Int? {
        let query = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !query.isEmpty else { return nil }

        let tokens = query.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        guard tokens.allSatisfy(searchBlob.contains) else { return nil }

        let normalizedTitle = title.localizedLowercase
        let normalizedSubtitle = subtitle.localizedLowercase

        if normalizedTitle == query {
            return 500
        }
        if normalizedTitle.hasPrefix(query) {
            return 420
        }
        if normalizedTitle.contains(query) {
            return 320
        }
        if normalizedSubtitle.contains(query) {
            return 220
        }
        return 140
    }

    /// Built once: entries depend only on build flags and `AppIconManager.isSupported`.
    static let all: [SettingsSearchEntry] = {
        var entries = SettingsSection.allCases.filter(\.isAvailable).map(\.searchEntry)
        entries += SettingsSearchDestination.allCases.filter(\.isAvailable).map(\.searchEntry)
        entries += rows.filter(\.isAvailable)
        #if DEBUG
        let ids = entries.map(\.id)
        assert(Set(ids).count == ids.count, "Duplicate settings search ids")
        #endif
        return entries
    }()

    static var suggested: [SettingsSearchEntry] {
        all.filter(\.isSuggested).prefix(8).map { $0 }
    }

    static func filtered(for query: String) -> [SettingsSearchEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return suggested }

        let matches: [(entry: SettingsSearchEntry, score: Int)] = all.compactMap { entry in
                guard let score = entry.matchScore(for: trimmedQuery) else { return nil }
                return (entry: entry, score: score)
            }

        return matches
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title) == .orderedAscending
            }
            .map(\.entry)
    }

    // MARK: - Rows that are not their own screen

    /// A setting that lives inside a leaf screen. Inherits the parent's gate.
    private static func row(
        _ id: String,
        _ title: String,
        in destination: SettingsSearchDestination,
        icon: String? = nil,
        keywords: [String],
        available: Bool = true,
        suggested: Bool = false
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: id,
            title: title,
            subtitle: destination.title,
            systemImage: icon ?? destination.systemImage,
            action: .destination(destination),
            keywords: keywords,
            isSuggested: suggested,
            isAvailable: destination.isAvailable && available
        )
    }

    /// A toggle or picker shown inline on a section screen.
    private static func row(
        _ id: String,
        _ title: String,
        in section: SettingsSection,
        icon: String,
        keywords: [String],
        available: Bool = true,
        suggested: Bool = false
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: id,
            title: title,
            subtitle: section.title,
            systemImage: icon,
            action: .section(section),
            keywords: keywords,
            isSuggested: suggested,
            isAvailable: section.isAvailable && available
        )
    }

    /// Hand-maintained, grouped by the screen the row lives on. When adding a
    /// toggle to a detail screen, add its entry under that screen's MARK.
    private static var rows: [SettingsSearchEntry] {
        let onPhone = SearchBuild.isPhone
        let isCatalyst = SearchBuild.isCatalyst
        let isVisionOS = SearchBuild.isVisionOS
        let isStandaloneMac = SearchBuild.isStandalone && isCatalyst
        let isTouch = !isCatalyst && !isVisionOS

        return [
            // MARK: Theme
            row("theme-match-system", String(localized: "Match System Theme"), in: .theme, icon: "circle.lefthalf.filled",
                keywords: ["day night", "automatic", "system appearance", "light dark"]),
            row("theme-create", String(localized: "Create Theme"), in: .theme, icon: "paintbrush",
                keywords: ["custom theme", "theme editor", "new theme"]),
            row("theme-import", String(localized: "Import Theme File"), in: .theme, icon: "square.and.arrow.down",
                keywords: ["import", "ghostty theme", ".conf"]),
            row("theme-ui-colors", String(localized: "Customize UI Colors"), in: .theme,
                keywords: ["ui overrides", "ui colors", "chrome colors"]),

            // MARK: Appearance Mode
            row("theme-aware-ui", String(localized: "Theme-Aware UI"), in: .appearanceMode,
                keywords: ["ui colors", "tinted", "chrome", "theme aware"]),
            row("im-no-fun", String(localized: "I'm no fun"), in: .appearanceMode, icon: "face.smiling",
                keywords: ["jokes", "quips", "ascii", "animations", "failure", "humor"]),

            // MARK: Transparency (Catalyst)
            row("transparency-opacity", String(localized: "Opacity"), in: .transparency,
                keywords: ["window opacity", "transparent", "see-through"]),
            row("transparency-blur", String(localized: "Background Blur"), in: .transparency,
                keywords: ["blur style", "blur radius", "glass", "frosted"]),
            row("transparency-sidebar", String(localized: "Transparent Pinned Sidebar"), in: .transparency,
                keywords: ["sidebar", "transparent"]),

            // MARK: Window
            row("window-tab-bar", String(localized: "Show Top Tab Bar"), in: .window,
                keywords: ["tab bar", "hide tabs", "tabs"]),
            row("window-tab-style", String(localized: "Tab Style"), in: .window,
                keywords: ["tab appearance", "compact"]),
            row("window-tab-shortcuts", String(localized: "Show Tab Shortcuts"), in: .window,
                keywords: ["tab numbers", "cmd number"]),
            row("window-group-menu", String(localized: "Show Group Menu"), in: .window,
                keywords: ["group", "project switcher"]),
            row("window-tab-animations", String(localized: "Disable Tab Animations"), in: .window,
                keywords: ["animation", "motion"]),
            row("window-expose-captions", String(localized: "Tab Exposé Captions"), in: .window,
                keywords: ["expose", "captions", "previews"]),
            row("window-hover-previews", String(localized: "Tab Hover Previews"), in: .window,
                keywords: ["hover", "activation", "preview size"], available: !isVisionOS && !onPhone),
            row("window-translucent-switcher", String(localized: "Translucent Tab Switcher"), in: .window,
                keywords: ["translucent", "blur", "switcher"], available: !isVisionOS && onPhone),
            row("window-translucent-sidebar", String(localized: "Translucent Tab Sidebar"), in: .window,
                keywords: ["translucent", "blur", "sidebar"], available: !isVisionOS && !onPhone),
            row("window-auto-hide-sidebar", String(localized: "Auto-Hide Sidebar After Selection"), in: .window,
                keywords: ["sidebar", "auto hide"], available: !isVisionOS && !onPhone),
            row("window-switcher-title-lines", String(localized: "Tab Switcher Title Lines"), in: .window,
                keywords: ["title lines", "wrap"], available: onPhone),
            row("window-sidebar-title-lines", String(localized: "Sidebar Title Lines"), in: .window,
                keywords: ["title lines", "wrap"], available: !onPhone),
            row("window-tabs-in-titlebar", String(localized: "Tabs in Title Bar"), in: .window,
                keywords: ["titlebar", "tabs"], available: isCatalyst),
            row("window-hide-titlebar", String(localized: "Hide Title Bar"), in: .window,
                keywords: ["titlebar", "hide"], available: isCatalyst),
            row("window-padding", String(localized: "Window Padding"), in: .window,
                keywords: ["horizontal", "vertical", "padding", "margins", "inset"]),
            row("window-split-border", String(localized: "Split Focus Border"), in: .window,
                keywords: ["split panes", "border", "border color", "focus"]),
            row("window-full-screen", String(localized: "Full Screen"), in: .window,
                keywords: ["status bar", "immersive"], available: isTouch),
            row("window-always-on", String(localized: "Always On Display"), in: .window,
                keywords: ["idle timer", "sleep", "screen lock", "stay awake"], available: isTouch),
            row("window-home-indicator", String(localized: "Extend Under Home Indicator"), in: .window,
                keywords: ["home indicator", "safe area"], available: isTouch),
            row("window-brightness-boost", String(localized: "Brightness Boost"), in: .window,
                keywords: ["hdr", "edr", "brightness"], available: !isVisionOS && SearchBuild.hasBrightnessBoost),
            row("window-selection-style", String(localized: "Selection Style"), in: .window,
                keywords: ["text selection", "selection colors", "foreground", "background"]),
            row("window-copy-on-select", String(localized: "Copy on Select"), in: .window,
                keywords: ["copy", "select", "clipboard"]),
            row("window-selection-loupe", String(localized: "Use Native Selection Loupe"), in: .window,
                keywords: ["loupe", "magnifier", "selection"], available: isTouch),

            // MARK: Cursor
            row("cursor-effect", String(localized: "Cursor Effect"), in: .cursor,
                keywords: ["effect", "trail", "glow"]),
            row("cursor-blinking", String(localized: "Blinking"), in: .cursor,
                keywords: ["blink", "blink style"]),
            row("cursor-color", String(localized: "Custom Cursor Color"), in: .cursor,
                keywords: ["cursor color", "text under cursor"]),
            row("cursor-opacity", String(localized: "Cursor Opacity"), in: .cursor,
                keywords: ["opacity"]),
            row("cursor-size", String(localized: "Cursor Size"), in: .cursor,
                keywords: ["thickness", "height", "size adjustments"]),

            // MARK: Font
            row("font-size", String(localized: "Font Size"), in: .font,
                keywords: ["size", "pt", "points"]),
            row("font-cell-spacing", String(localized: "Cell Spacing"), in: .font,
                keywords: ["width", "height", "line height", "letter spacing", "cell"]),
            row("font-ligatures", String(localized: "Enable Ligatures"), in: .font,
                keywords: ["ligatures", "font features"]),
            row("font-stylistic-sets", String(localized: "Stylistic Sets"), in: .font,
                keywords: ["font features", "ss01", "stylistic"]),
            row("font-import", String(localized: "Import Font"), in: .font, icon: "plus.circle",
                keywords: ["custom font", "ttf", "otf", "install font"]),

            // MARK: Colors
            row("palette-generate", String(localized: "Generate Palette"), in: .palette,
                keywords: ["generate", "256", "ansi"]),
            row("palette-harmonious", String(localized: "Harmonious Mode"), in: .palette, icon: "circle.lefthalf.filled",
                keywords: ["harmonious", "harmony"]),

            // MARK: Battery
            row("battery-refresh-rate", String(localized: "Maximum Refresh Rate"), in: .battery, icon: "gauge.with.dots.needle.67percent",
                keywords: ["fps", "hz", "promotion", "adaptive", "on battery"]),
            row("battery-saver", String(localized: "Automatic Battery Saver"), in: .battery,
                keywords: ["saver", "low power"]),

            // MARK: Background Effect
            row("effect-pinned-sidebar", String(localized: "Include Pinned Sidebar"), in: .backgroundEffect,
                keywords: ["layout", "sidebar", "effect"]),
            row("effect-photo", String(localized: "Photo Background"), in: .backgroundEffect, icon: "photo",
                keywords: ["photo", "image", "wallpaper", "ken burns", "filter", "tint"]),
            row("effect-video", String(localized: "Video Background"), in: .backgroundEffect, icon: "film",
                keywords: ["video", "looping", "wallpaper", "local video", "photos"]),

            // MARK: Custom Shaders
            row("shader-import", String(localized: "Import Shader"), in: .customShaders, icon: "square.and.arrow.down",
                keywords: ["glsl", "shadertoy", "metal", "import"]),
            row("shader-animation", String(localized: "Shader Animation"), in: .customShaders,
                keywords: ["animation", "pause", "motion"]),

            // MARK: Visor (Standalone Mac)
            row("visor-enable", String(localized: "Enable Visor"), in: .visor,
                keywords: ["enable", "visor"]),
            row("visor-hotkey", String(localized: "Visor Hotkey"), in: .visor, icon: "command",
                keywords: ["combination", "key", "global shortcut", "modifier"]),
            row("visor-position", String(localized: "Visor Position"), in: .visor,
                keywords: ["edge", "screen", "space"], available: isCatalyst),
            row("visor-size", String(localized: "Visor Size"), in: .visor,
                keywords: ["slide size", "cross axis", "percent", "pixels"], available: isCatalyst),
            row("visor-auto-hide", String(localized: "Auto-hide when focus moves to another app"), in: .visor,
                keywords: ["auto hide", "focus"], available: isCatalyst),
            row("visor-event-tap", String(localized: "Use event tap"), in: .visor,
                keywords: ["accessibility", "permission", "event tap"], available: isCatalyst),

            // MARK: Terminal › Keyboard (inline)
            row("terminal-writing-assistance", String(localized: "Writing Assistance"), in: .terminal,
                icon: TerminalWritingAssistanceMode.toolbarIcon,
                keywords: ["keyboard", "typing", "suggestions", "autocorrect", "autocorrection",
                           "spell checking", "spellcheck", "spelling", "completion", "software keyboard"],
                available: !isCatalyst),
            row("double-space-period", String(localized: "\"\u{200B}.\u{200B}\" Shortcut"), in: .terminal, icon: "character.cursor.ibeam",
                keywords: ["double", "space", "period", "shortcut", "keyboard"], available: !isCatalyst),
            row("persistent-toolbar", String(localized: "Persistent Toolbar"), in: .terminal, icon: "arrow.up.and.down.text.horizontal",
                keywords: ["toolbar", "keyboard dismissed", "keep visible"], available: isTouch),
            row("toolbar-hardware-keyboard", String(localized: "Show Toolbar with Hardware Keyboard"), in: .terminal, icon: "keyboard.badge.ellipsis",
                keywords: ["toolbar", "hardware keyboard", "docked"], available: isTouch),
            row("option-key-as-alt", String(localized: "Option Key as Alt"), in: .terminal, icon: "option",
                keywords: ["meta", "modifier", "keyboard"]),

            // MARK: Terminal › Gestures (inline)
            row("tab-expose-gesture", String(localized: "Pull Down for Tab Exposé"), in: .terminal, icon: "rectangle.stack",
                keywords: ["expose", "tab previews", "pull down", "swipe down", "gesture"], available: !isVisionOS),
            row("two-finger-long-press", String(localized: "Two-Finger Long Press"), in: .terminal, icon: "hand.point.up.left",
                keywords: ["gesture", "new connection", "duration", "long press"], available: !isCatalyst),

            // MARK: Terminal › Session (inline)
            row("restore-sessions", String(localized: "Restore Sessions on Launch"), in: .terminal, icon: "arrow.counterclockwise",
                keywords: ["session restore", "startup"], suggested: true),
            row("persist-scrollback", String(localized: "Persist Scrollback History"), in: .terminal, icon: "clock.arrow.circlepath",
                keywords: ["history", "scrollback", "logs"]),

            // MARK: Terminal › Shell (inline)
            row("scroll-mode", String(localized: "Scroll Mode"), in: .terminal, icon: "hand.draw",
                keywords: ["touch", "gesture", "selection"], available: !isCatalyst),
            row("line-scrolling", String(localized: "Use Line Scrolling"), in: .terminal, icon: "line.3.horizontal",
                keywords: ["scroll", "pixel", "smooth", "line", "legacy"]),
            row("rubber-band-scrolling", String(localized: "Rubber Band Scrolling"), in: .terminal, icon: "arrow.up.arrow.down",
                keywords: ["scroll", "pixel", "smooth", "bounce", "rubber", "band"]),

            // MARK: Toolbar Keys (touch)
            row("toolbar-custom-keys", String(localized: "Custom Keys"), in: .toolbarKeys,
                keywords: ["new custom key", "macro", "sequence", "toolbar"]),
            row("toolbar-drawer-rows", String(localized: "Drawer Rows"), in: .toolbarKeys,
                keywords: ["drawer", "more button", "rows"]),
            row("toolbar-open-drawer", String(localized: "Open Drawer by Default"), in: .toolbarKeys,
                keywords: ["drawer", "default"]),

            // MARK: Keyboard Shortcuts
            row("keybinds-ghostty-import", String(localized: "Import Keybinds from Ghostty Config"), in: .keyboardShortcuts, icon: "doc.badge.plus",
                keywords: ["ghostty config", "keybind", "import", "reload"]),

            // MARK: Prompt & Username (touch)
            row("prompt-username", String(localized: "Username"), in: .promptAndUsername,
                keywords: ["username", "identity", "whoami"]),
            row("prompt-starship", String(localized: "Starship-style Prompt"), in: .promptAndUsername,
                keywords: ["starship", "prompt theme", "clock format", "git status"]),
            row("prompt-transient", String(localized: "Transient Prompt"), in: .promptAndUsername,
                keywords: ["starship", "transient"]),
            row("prompt-right", String(localized: "Right Prompt"), in: .promptAndUsername,
                keywords: ["starship", "right prompt"]),
            row("prompt-blank-line", String(localized: "Blank Line Before Prompt"), in: .promptAndUsername,
                keywords: ["starship", "blank line", "spacing"]),
            row("prompt-custom-config", String(localized: "Custom Starship Config"), in: .promptAndUsername,
                keywords: ["starship.toml", "config", "reload", "example"]),

            // MARK: Locale
            row("locale-ascii-keyboard", String(localized: "Force ASCII Keyboard"), in: .locale,
                keywords: ["ascii", "keyboard layout", "input source"], available: !isCatalyst),

            // MARK: IP Geolocation
            row("geo-mmdb", String(localized: "Local MMDB Databases"), in: .ipGeolocation, icon: "internaldrive",
                keywords: ["mmdb", "maxmind", "geoip", "database", "import"]),
            row("geo-wifi-info", String(localized: "Enable WiFi Info"), in: .ipGeolocation, icon: "wifi",
                keywords: ["wifi", "ssid", "location permission"], available: !isCatalyst),

            // MARK: Multiplexers
            row("mux-discover-tmux", String(localized: "Discover tmux Sessions"), in: .multiplexers,
                keywords: ["tmux", "discovery"]),
            row("mux-discover-zellij", String(localized: "Discover zellij Sessions"), in: .multiplexers,
                keywords: ["zellij", "discovery"]),
            row("mux-discover-herdr", String(localized: "Discover herdr Sessions"), in: .multiplexers,
                keywords: ["herdr", "discovery"]),
            row("mux-discover-zmx", String(localized: "Discover zmx Sessions"), in: .multiplexers,
                keywords: ["zmx", "discovery"]),
            row("mux-discover-local", String(localized: "Discover Local Sessions"), in: .multiplexers, icon: "desktopcomputer",
                keywords: ["local", "discovery"], available: isCatalyst),
            row("mux-sort-order", String(localized: "Sort Order"), in: .multiplexers, icon: "arrow.up.arrow.down",
                keywords: ["sort", "sessions"]),
            row("mux-show-tabs", String(localized: "Show Multiplexer Tabs"), in: .multiplexers, icon: "rectangle.grid.2x2",
                keywords: ["tab exposé", "multiplexer tabs"]),
            row("mux-auto-hide-gateway", String(localized: "Auto-hide Gateway on Attach"), in: .multiplexers, icon: "eye.slash",
                keywords: ["control mode", "gateway", "attach"]),
            row("mux-close-tab-action", String(localized: "Close Tab Action"), in: .multiplexers, icon: "xmark.rectangle",
                keywords: ["tmux", "close tab", "kill window", "detach"]),
            row("mux-auto-start", String(localized: "Auto-Start Command"), in: .multiplexers, icon: "play.rectangle",
                keywords: ["tmux", "herdr", "zmx", "auto start", "attach"]),
            row("mux-tips", String(localized: "Multiplexer Tips"), in: .multiplexers, icon: "questionmark.circle",
                keywords: ["guide", "tips", "help"]),

            // MARK: Coding Agents
            row("agent-notifications", String(localized: "Agent Notifications"), in: .codingAgents, icon: "bell.and.waves.left.and.right",
                keywords: ["agent", "notify", "banner", "blocked", "needs input", "done"]),
            row("agent-badges", String(localized: "Show Attention Badges"), in: .codingAgents, icon: "circlebadge.fill",
                keywords: ["badge", "attention", "tab"]),
            row("agent-project-details", String(localized: "Look Up Project Details"), in: .codingAgents, icon: "folder.badge.questionmark",
                keywords: ["project", "folder", "git", "details"]),
            row("agent-subscription-usage", String(localized: "Show Subscription Usage"), in: .codingAgents, icon: "gauge.with.needle",
                keywords: ["subscription", "usage", "quota", "claude", "gauge"]),
            row("agent-include-question", String(localized: "Include the Question"), in: .codingAgents, icon: "text.bubble",
                keywords: ["notification detail", "question", "agent notifications"]),

            // MARK: Command Detection
            row("task-notifications", String(localized: "Command Notifications"), in: .taskDetection, icon: "bell.and.waves.left.and.right",
                keywords: ["command", "notify", "banner", "waiting", "input", "finished", "failed"]),
            row("task-detect", String(localized: "Detect Long-Running Commands"), in: .taskDetection,
                keywords: ["long running", "command", "detection"]),
            row("task-input-prompts", String(localized: "Input Prompts"), in: .taskDetection, icon: "questionmark.key.filled",
                keywords: ["sudo", "host key", "y/n", "confirmation", "password prompt"]),
            row("task-test-runs", String(localized: "Test Runs"), in: .taskDetection, icon: "checklist",
                keywords: ["pytest", "jest", "go test", "cargo test", "swift test"]),
            row("task-builds", String(localized: "Builds"), in: .taskDetection, icon: "hammer",
                keywords: ["cargo", "ninja", "xcodebuild", "build"]),
            row("task-infrastructure", String(localized: "Infrastructure"), in: .taskDetection, icon: "server.rack",
                keywords: ["terraform", "kubectl", "docker"]),
            row("task-file-transfers", String(localized: "File Transfers"), in: .taskDetection, icon: "arrow.up.arrow.down.circle",
                keywords: ["rsync", "scp", "curl", "wget", "transfer"]),
            row("task-include-prompt", String(localized: "Include the Prompt"), in: .taskDetection, icon: "text.bubble",
                keywords: ["notification detail", "prompt", "command notifications"]),

            // MARK: SSH Keys
            row("ssh-yubikey", String(localized: "YubiKey"), in: .sshKeys, icon: "key.viewfinder",
                keywords: ["hardware key", "piv", "nfc", "smart card", "usb-c"]),
            row("ssh-generate-key", String(localized: "Generate New Key"), in: .sshKeys, icon: "wand.and.stars",
                keywords: ["ed25519", "rsa", "ecdsa", "generate", "secure enclave"]),
            row("ssh-import-key", String(localized: "Import Existing Key"), in: .sshKeys, icon: "square.and.arrow.down",
                keywords: ["import", "pem", "openssh", "private key"]),
            row("ssh-import-certificate", String(localized: "Import Certificate"), in: .sshKeys, icon: "checkmark.seal",
                keywords: ["user certificate", "cert", "signed key"]),
            row("ssh-openpubkey", String(localized: "Sign In with OpenPubkey"), in: .sshKeys, icon: "person.badge.key",
                keywords: ["openpubkey", "oidc", "sso", "google", "github"]),
            row("ssh-import-from-agent", String(localized: "Import from SSH Agent"), in: .sshKeys, icon: "key.radiowaves.forward",
                keywords: ["agent", "socket", "1password", "secretive"], available: isStandaloneMac),
            row("ssh-passkey", String(localized: "Passkey"), in: .sshKeys, icon: "person.badge.key.fill",
                keywords: ["passkey", "webauthn", "icloud keychain"]),
            row("ssh-fido2", String(localized: "FIDO2 Security Key"), in: .sshKeys, icon: "key.viewfinder",
                keywords: ["fido2", "security key", "resident key", "sk-ssh"], available: !isVisionOS),

            // MARK: Saved Passwords
            row("passwords-default-security", String(localized: "Default Security Settings"), in: .savedPasswords,
                keywords: ["storage level", "authentication", "biometric", "keychain", "face id"]),

            // MARK: SSH Transport
            row("force-ipv4", String(localized: "Force IPv4"), in: .sshTransport, icon: "network",
                keywords: ["ipv4", "ipv6", "network", "dns"]),
            row("background-session-keepalive", String(localized: "Keep TCP SSH Alive in Background"), in: .sshTransport, icon: "bolt.horizontal",
                keywords: ["background", "battery", "keepalive", "tcp", "ssh", "tssh", "mosh", "connections"],
                available: isTouch),
            row("connection-health", String(localized: "Connection Health Monitoring"), in: .sshTransport, icon: "heart.text.square",
                keywords: ["probe", "interval", "health", "keepalive", "ssh"]),
            row("probe-interval", String(localized: "Probe Interval"), in: .sshTransport, icon: "timer",
                keywords: ["connection health", "monitoring", "keepalive", "ssh"]),
            row("public-key-compat", String(localized: "OpenSSH Public Key Compatibility"), in: .sshTransport, icon: "key",
                keywords: ["public key", "libssh2", "compatibility", "router", "embedded"]),
            row("post-quantum-warning", String(localized: "Post-Quantum Warning"), in: .sshTransport,
                keywords: ["ssh", "pq", "kex", "key exchange", "security", "post quantum"]),

            // MARK: Local SSH Agent (Standalone Mac)
            row("local-agent-enable", String(localized: "Enable Local SSH Agent"), in: .localSSHAgent,
                keywords: ["enable", "agent"]),
            row("local-agent-approval", String(localized: "Signature Approval"), in: .localSSHAgent,
                keywords: ["approve", "prompt", "sign", "per client"]),
            row("local-agent-expose", String(localized: "Expose All SSH Keys"), in: .localSSHAgent,
                keywords: ["expose", "keys", "agent"]),
            row("local-agent-audit", String(localized: "Audit Log"), in: .localSSHAgent, icon: "list.bullet.rectangle",
                keywords: ["audit", "log", "clients", "history"]),

            // MARK: Roam
            row("roam-hole-punch", String(localized: "Enable Hole-Punch"), in: .roam,
                keywords: ["mosh", "nat", "hole punch", "udp"]),
            row("roam-prediction", String(localized: "Default Prediction Mode"), in: .roam,
                keywords: ["mosh", "prediction", "local echo"]),
            row("roam-overwrite-predictions", String(localized: "Overwrite Predictions"), in: .roam,
                keywords: ["mosh", "prediction"]),
            row("roam-alternate-screen", String(localized: "Use Alternate Screen"), in: .roam,
                keywords: ["mosh", "alt screen", "alternate"]),
            row("roam-transport", String(localized: "Default Transport"), in: .roam,
                keywords: ["tssh", "transport", "udp", "tcp"]),
            row("roam-discard-offline", String(localized: "Discard Input While Offline"), in: .roam,
                keywords: ["tssh", "offline", "queue input"]),
            row("roam-port-range", String(localized: "Port Range"), in: .roam,
                keywords: ["tssh", "port range", "min", "max", "61000"]),
            row("roam-mptcp", String(localized: "Multipath TCP"), in: .roam,
                keywords: ["mptcp", "multipath", "ssh", "wifi", "cellular"]),
            row("roam-guides", String(localized: "Roam Setup Guides"), in: .roam, icon: "questionmark.circle",
                keywords: ["guide", "tsshd", "mptcp", "hole punch", "server setup"]),

            // MARK: Screen Sharing
            row("screen-sharing-ctrl-opt", String(localized: "Control+Option as Command"), in: .screenSharing, icon: "keyboard",
                keywords: ["hardware keyboard", "command key", "vnc", "mac"]),
            row("screen-sharing-reserved", String(localized: "Route Reserved Shortcuts to VNC"), in: .screenSharing, icon: "keyboard.badge.ellipsis",
                keywords: ["reserved shortcuts", "keyboard", "vnc"]),
            row("screen-sharing-clipboard", String(localized: "Default Clipboard Sync"), in: .screenSharing, icon: "arrow.triangle.2.circlepath",
                keywords: ["shared clipboard", "copy", "paste", "auto", "secure", "always on", "off"]),
            row("screen-sharing-panning", String(localized: "Screen Panning"), in: .screenSharing, icon: "cursorarrow.motionlines",
                keywords: ["pointer", "edge", "continuous", "pan", "viewport",
                           "default mode", "when pointer reaches edge", "continuously with pointer"]),
            row("screen-sharing-pointer-mode", String(localized: "Default Pointer Mode"), in: .screenSharing, icon: "cursorarrow.rays",
                keywords: ["pointer", "trackpad", "touch", "cursor", "relative", "absolute",
                           "default mode", "mouse"]),
            row("screen-sharing-pointer-speed", String(localized: "Pointer Speed"), in: .screenSharing, icon: "speedometer",
                keywords: ["pointer", "trackpad", "speed", "sensitivity", "acceleration", "cursor"]),
            row("screen-sharing-cursor-rendering", String(localized: "Cursor Rendering"), in: .screenSharing, icon: "cursorarrow",
                keywords: ["cursor", "pointer", "remote", "local",
                           "server rendered", "draw", "mouse"]),
            row("screen-sharing-cursor-size", String(localized: "Cursor Size"), in: .screenSharing, icon: "arrow.up.left.and.arrow.down.right",
                keywords: ["cursor", "pointer", "size", "small", "medium", "large",
                           "bigger", "trackpad"]),

            // MARK: Connections (inline)
            row("clear-connection-history", String(localized: "Clear Connection History"), in: .connections, icon: "trash",
                keywords: ["history", "recent connections"]),

            // MARK: AI Configuration
            row("ai-openai", String(localized: "OpenAI"), in: .aiConfiguration,
                keywords: ["api key", "chatgpt", "sign in", "codex", "gpt", "temperature", "models", "reasoning"]),
            row("ai-anthropic", String(localized: "Anthropic"), in: .aiConfiguration,
                keywords: ["api key", "claude", "temperature", "models"]),
            row("ai-bedrock", String(localized: "AWS Bedrock"), in: .aiConfiguration,
                keywords: ["aws", "account", "region", "temperature", "models"]),
            row("ai-gemini", String(localized: "Google Gemini"), in: .aiConfiguration,
                keywords: ["google", "gemini", "api key", "temperature", "models"]),
            row("ai-openrouter", String(localized: "OpenRouter"), in: .aiConfiguration,
                keywords: ["api key", "models", "free models", "provider", "tier"]),
            row("ai-custom-providers", String(localized: "Custom AI Providers"), in: .aiConfiguration, icon: "plus",
                keywords: ["custom provider", "ollama", "openai-compatible", "endpoint", "local model", "add model"]),
            row("ai-web-search", String(localized: "Enable Web Search"), in: .aiConfiguration, icon: "magnifyingglass",
                keywords: ["web search", "default engine", "search engine"]),
            row("ai-commit-messages", String(localized: "AI Commit Messages"), in: .aiConfiguration,
                keywords: ["git", "commit", "message", "model"], available: !isCatalyst),
            row("ai-presentation", String(localized: "AI Presentation"), in: .aiConfiguration, icon: "sidebar.right",
                keywords: ["display mode", "presentation", "layout"], available: !isVisionOS && !onPhone),

            // MARK: Voice Agent
            row("voice-selection", String(localized: "Voice"), in: .voiceAgent,
                keywords: ["voice selection", "speech", "tts"]),
            row("voice-expert", String(localized: "Expert Consultation"), in: .voiceAgent,
                keywords: ["expert model", "consult"]),

            // MARK: MCP Server
            row("mcp-enable", String(localized: "Enable MCP Server"), in: .mcpServer,
                keywords: ["mcp", "server", "enable"]),
            row("mcp-session-mode", String(localized: "Session Mode"), in: .mcpServer, icon: "lock.shield",
                keywords: ["security", "standard", "cautious", "yolo", "permissions", "confirm"]),
            row("mcp-add-to-tools", String(localized: "Add to AI Tools"), in: .mcpServer, icon: "doc.on.doc",
                keywords: ["claude code", "codex", "install", "connect", "command"]),

            // MARK: iCloud Sync
            row("icloud-enable", String(localized: "Enable iCloud Sync"), in: .iCloudSync,
                keywords: ["icloud", "sync", "enable"]),
            row("icloud-ssh-history", String(localized: "Sync SSH History"), in: .iCloudSync,
                keywords: ["ssh history", "sync"]),
            row("icloud-known-hosts", String(localized: "Sync Known Hosts"), in: .iCloudSync,
                keywords: ["known hosts", "sync"]),
            row("icloud-profiles", String(localized: "Sync Connection Profiles"), in: .iCloudSync,
                keywords: ["profiles", "connections", "sync"]),
            row("icloud-settings", String(localized: "Sync Settings"), in: .iCloudSync,
                keywords: ["settings sync", "app settings", "icloud"]),

            // MARK: Config File
            row("config-allow-edit", String(localized: "Allow Settings to Edit This File"), in: .configFile,
                keywords: ["write back", "edit", "config file"]),
            row("config-external", String(localized: "External Config File"), in: .configFile, icon: "folder",
                keywords: ["choose external file", "symlink", "dotfiles", "stop using"]),
            row("config-export", String(localized: "Export Current Settings"), in: .configFile, icon: "square.and.arrow.up",
                keywords: ["export", "dump", "config"]),

            // MARK: Backup & Restore
            row("backup-create", String(localized: "Create Backup"), in: .backupRestore,
                keywords: ["create", "encrypt", "password", "categories", "share"]),
            row("backup-restore", String(localized: "Restore Backup"), in: .backupRestore,
                keywords: ["restore", "select backup file", "password"]),

            // MARK: Privacy & Data (inline, touch)
            row("location-diary-mode", String(localized: "Location Diary Mode"), in: .privacyData, icon: "mappin.and.ellipse",
                keywords: ["tracking", "location", "diary", "session only", "auto during active sessions"],
                available: !isCatalyst),

            // MARK: Live Activity
            row("live-activity-filter", String(localized: "Session Filter"), in: .liveActivity, icon: "line.3.horizontal.decrease.circle",
                keywords: ["filter", "sessions", "live activity"]),
            row("live-activity-wifi", String(localized: "WiFi Info"), in: .liveActivity, icon: "wifi",
                keywords: ["wifi", "ssid", "live activity"]),
            row("live-activity-network", String(localized: "Network Info"), in: .liveActivity, icon: "network",
                keywords: ["network", "ip", "live activity"]),
            row("live-activity-agents", String(localized: "Coding Agents"), in: .liveActivity, icon: "sparkles",
                keywords: ["agents", "claude", "codex", "coding", "attention", "live activity"]),

            // MARK: Clipboard Manager
            row("clipboard-biometrics", String(localized: "Require Face ID / Touch ID to Open"), in: .clipboardManager, icon: "faceid",
                keywords: ["biometric", "face id", "touch id", "optic id", "lock"]),
            row("clipboard-keep-history", String(localized: "Keep History"), in: .clipboardManager, icon: "clock.arrow.circlepath",
                keywords: ["retention", "days", "history"]),

            // MARK: Auto-Redact
            row("redact-enable", String(localized: "Redact Sensitive Text"), in: .autoRedact,
                keywords: ["redact", "enable"]),
            row("redact-strings", String(localized: "Redacted Strings"), in: .autoRedact, icon: "lock",
                keywords: ["add string", "name", "email", "reveal", "custom"]),

            // MARK: Push Notifications
            row("push-background-only", String(localized: "Only When in Background"), in: .pushNotifications, icon: "moon.zzz",
                keywords: ["background", "foreground", "push"]),
            row("push-agent-logos", String(localized: "Show Agent Logos"), in: .pushNotifications, icon: "photo",
                keywords: ["logo", "icon", "push"]),
            row("push-pair", String(localized: "Pair a Computer"), in: .pushNotifications, icon: "plus.circle",
                keywords: ["pair", "pairing", "computer", "hook", "remote"]),
            row("push-hook-client", String(localized: "Install the Hook Client"), in: .pushNotifications, icon: "terminal",
                keywords: ["hook", "install", "upgrade", "shell command", "rootshell-push"]),

            // MARK: Notifications (inline)
            row("terminal-notifications", String(localized: "Terminal Notifications"), in: .notifications, icon: "bell",
                keywords: ["osc", "alerts"]),
            row("ssh-session-reminders", String(localized: "SSH Session Reminders"), in: .notifications, icon: "bell.badge",
                keywords: ["background", "reminders"], available: !isCatalyst),
            row("bell-sound", String(localized: "Bell Sound"), in: .notifications, icon: "speaker.wave.2",
                keywords: ["audio", "alerts"]),
            row("notification-sound", String(localized: "Notification Sound"), in: .notifications, icon: "music.note",
                keywords: ["audio", "reminders"]),
            row("volume", String(localized: "Volume"), in: .notifications, icon: "speaker.wave.3",
                keywords: ["sound level", "bell volume"]),
            row("updates-automatic", String(localized: "Automatically Check for Updates"), in: .notifications, icon: "arrow.down.circle",
                keywords: ["sparkle", "update", "check interval", "daily", "weekly"], available: isStandaloneMac),
            row("updates-check-now", String(localized: "Check for Updates Now"), in: .notifications, icon: "arrow.clockwise.circle",
                keywords: ["update", "check now", "version"], available: isStandaloneMac),
        ]
    }
}

/// The screen for each destination. Views whose files are `#if`-gated keep an
/// `EmptyView()` fallback; `isAvailable` keeps those branches unreachable.
@ViewBuilder
func settingsSearchDestinationView(for destination: SettingsSearchDestination) -> some View {
    switch destination {
    case .appIcon:
        AppIconSettingsView()
    case .theme:
        ThemeSettingsView()
    case .font:
        FontSettingsView()
    case .cursor:
        CursorSettingsView()
    case .palette:
        PaletteSettingsView()
    case .appearanceMode:
        AppearanceModeSettingsView()
    case .backgroundEffect:
        EffectSettingsView()
    case .customShaders:
        ShaderSettingsView()
    case .transparency:
        #if targetEnvironment(macCatalyst)
        TransparencySettingsView()
        #else
        EmptyView()
        #endif
    case .window:
        WindowSettingsView()
    case .battery:
        BatterySettingsView()
    case .visor:
        #if STANDALONE && targetEnvironment(macCatalyst)
        VisorSettingsView()
        #elseif os(iOS)
        iPadVisorSettingsView()
        #else
        EmptyView()
        #endif
    case .toolbarKeys:
        #if !targetEnvironment(macCatalyst)
        KeyboardToolbarSettingsView()
        #else
        EmptyView()
        #endif
    case .newTabAction:
        NewTabActionPickerView()
    case .keyboardShortcuts:
        KeyboardShortcutsSettingsView()
    case .modTap:
        ModTapSettingsView()
    case .swipeGestures:
        SwipeGesturesSettingsView()
    case .promptAndUsername:
        #if !targetEnvironment(macCatalyst)
        PromptSettingsView()
        #else
        EmptyView()
        #endif
    case .bookmarkedLocations:
        #if !targetEnvironment(macCatalyst)
        BookmarkedLocationsView()
        #else
        EmptyView()
        #endif
    case .locale:
        LocaleSettingsView()
    case .terminalType:
        TerminalTypeSettingsView()
    case .localShell:
        #if STANDALONE && targetEnvironment(macCatalyst)
        LocalShellSettingsView()
        #else
        EmptyView()
        #endif
    case .ipGeolocation:
        GeoProviderSettingsView()
    case .sshKeys:
        SSHKeyManagementView()
    case .gpgKeys:
        GPGKeyManagementView()
    case .savedPasswords:
        SavedPasswordsView()
    case .knownHosts:
        KnownHostsView()
    case .hostCertificateAuthorities:
        HostCertificateAuthoritiesView()
    case .sshShortcuts:
        HSSConfigSettingsView()
    case .localSSHAgent:
        #if targetEnvironment(macCatalyst) && STANDALONE
        LocalSSHAgentSettingsView()
        #else
        EmptyView()
        #endif
    case .externalSSHAgents:
        #if targetEnvironment(macCatalyst) && STANDALONE
        ExternalSSHAgentsView()
        #else
        EmptyView()
        #endif
    case .cloudProviders:
        CloudProvidersSettingsView()
    case .wifiAPProviders:
        WiFiAPProvidersSettingsView()
    case .kubernetesClusters:
        KubernetesSettingsView()
    case .backgroundTunnels:
        TunnelSettingsView()
    case .vpn:
        #if !CHINA_BUILD && (!targetEnvironment(macCatalyst) || STANDALONE)
        VPNSettingsView()
        #else
        EmptyView()
        #endif
    case .roam:
        RoamSettingsView()
    case .screenSharing:
        ScreenSharingSettingsView()
    case .sshTransport:
        SSHTransportSettingsView()
    case .multiplexers:
        MultiplexerSettingsView()
    case .codingAgents:
        CodingAgentSettingsView()
    case .taskDetection:
        TaskDetectionSettingsView()
    case .pushNotifications:
        PushNotificationSettingsView()
    case .aiConfiguration:
        #if !CHINA_BUILD
        AIAgentSettingsView()
        #else
        EmptyView()
        #endif
    case .aiTextSize:
        #if !CHINA_BUILD
        AIAgentFontSettingsView()
        #else
        EmptyView()
        #endif
    case .mcpServer:
        #if !CHINA_BUILD
        MCPSettingsView()
        #else
        EmptyView()
        #endif
    case .voiceAgent:
        #if !CHINA_BUILD
        VoiceAgentSettingsView()
        #else
        EmptyView()
        #endif
    case .iCloudSync:
        CloudSyncSettingsView()
    case .backupRestore:
        BackupRestoreView()
    case .syncedGroups:
        SyncedGroupsView()
    case .pinnedSettings:
        PinnedSettingsView()
    case .configFile:
        ConfigFileSettingsView()
    case .locationDiary:
        #if !targetEnvironment(macCatalyst)
        LocationDiaryView()
        #else
        EmptyView()
        #endif
    case .liveActivity:
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveActivitySettingsView()
        #else
        EmptyView()
        #endif
    case .clipboardManager:
        ClipboardManagerSettingsView()
    case .autoRedact:
        AutoRedactSettingsView()
    case .acknowledgements:
        LicenseAcknowledgementsView()
    case .openSSHImport:
        OpenSSHImportView()
    case .ghosttyConfigImport:
        GhosttyConfigImportView()
    }
}
