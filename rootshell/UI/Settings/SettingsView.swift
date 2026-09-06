//
//  SettingsView.swift
//  rootshell
//
//  Settings view for configuring Ghostty
//

import SwiftUI
import UniformTypeIdentifiers

/// Navigation destinations for programmatic push (e.g., from Shortcuts intents).
enum SettingsDestination: Hashable {
    case vpn
}

/// Sidebar sections for the iPad split-view settings layout.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case terminal
    case connections
    case aiAssistant
    case privacyData
    case notifications
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: String(localized: "Appearance", comment: "Settings section title")
        case .terminal: String(localized: "Terminal", comment: "Settings section title")
        case .connections: String(localized: "Connections", comment: "Settings section title")
        case .aiAssistant: String(localized: "AI Assistant", comment: "Settings section title")
        case .privacyData: String(localized: "Privacy & Data", comment: "Settings section title")
        case .notifications: String(localized: "Notifications", comment: "Settings section title")
        case .about: String(localized: "About", comment: "Settings section title")
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintpalette"
        case .terminal: "terminal"
        case .connections: "network"
        case .aiAssistant: "sparkles"
        case .privacyData: "hand.raised"
        case .notifications: "bell"
        case .about: "info.circle"
        }
    }
}

enum SettingsSearchDestination: Hashable {
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
    case toolbarKeys
    case keyboardShortcuts
    case modTap
    case promptAndUsername
    case bookmarkedLocations
    case locale
    case terminalType
    case localShell
    case ipGeolocation
    case sshKeys
    case savedPasswords
    case knownHosts
    case hostCertificateAuthorities
    case sshShortcuts
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

    static var all: [SettingsSearchEntry] {
        var entries: [SettingsSearchEntry] = [
            .init(
                id: "section-appearance",
                title: String(localized: "Appearance"),
                subtitle: String(localized: "Settings"),
                systemImage: "paintpalette",
                action: .section(.appearance),
                keywords: ["theme", "font", "cursor", "window", "colors"],
                isSuggested: true
            ),
            .init(
                id: "section-terminal",
                title: String(localized: "Terminal"),
                subtitle: String(localized: "Settings"),
                systemImage: "terminal",
                action: .section(.terminal),
                keywords: ["keyboard", "locale", "prompt", "sessions"],
                isSuggested: true
            ),
            .init(
                id: "section-connections",
                title: String(localized: "Connections"),
                subtitle: String(localized: "Settings"),
                systemImage: "network",
                action: .section(.connections),
                keywords: ["ssh", "cloud", "vpn", "hosts", "tmux", "vnc", "screen sharing", "remote desktop"],
                isSuggested: true
            ),
            .init(
                id: "section-ai",
                title: String(localized: "AI Assistant"),
                subtitle: String(localized: "Settings"),
                systemImage: "sparkles",
                action: .section(.aiAssistant),
                keywords: ["providers", "mcp", "agent", "text size"],
                isSuggested: true
            ),
            .init(
                id: "section-privacy",
                title: String(localized: "Privacy & Data"),
                subtitle: String(localized: "Settings"),
                systemImage: "hand.raised",
                action: .section(.privacyData),
                keywords: ["icloud", "location", "sync", "live activity"],
                isSuggested: false
            ),
            .init(
                id: "section-notifications",
                title: String(localized: "Notifications"),
                subtitle: String(localized: "Settings"),
                systemImage: "bell",
                action: .section(.notifications),
                keywords: ["sound", "bell", "reminders"],
                isSuggested: false
            ),
            .init(
                id: "section-about",
                title: String(localized: "About"),
                subtitle: String(localized: "Settings"),
                systemImage: "info.circle",
                action: .section(.about),
                keywords: ["version", "acknowledgements", "licenses"],
                isSuggested: false
            ),

            .init(
                id: "theme",
                title: String(localized: "Theme"),
                subtitle: String(localized: "Appearance"),
                systemImage: "paintpalette",
                action: .destination(.theme),
                keywords: ["colors", "terminal theme"],
                isSuggested: true
            ),
            .init(
                id: "font",
                title: String(localized: "Font"),
                subtitle: String(localized: "Appearance"),
                systemImage: "textformat",
                action: .destination(.font),
                keywords: ["typeface", "size", "ligatures"],
                isSuggested: true
            ),
            .init(
                id: "cursor",
                title: String(localized: "Cursor"),
                subtitle: String(localized: "Appearance"),
                systemImage: "character.cursor.ibeam",
                action: .destination(.cursor),
                keywords: ["beam", "block", "underline"],
                isSuggested: false
            ),
            .init(
                id: "palette",
                title: String(localized: "Colors"),
                subtitle: String(localized: "Appearance"),
                systemImage: "swatchpalette",
                action: .destination(.palette),
                keywords: ["palette", "harmonious", "256", "generate", "colors"],
                isSuggested: false
            ),
            .init(
                id: "appearance-mode",
                title: String(localized: "Appearance Mode"),
                subtitle: String(localized: "Appearance"),
                systemImage: "circle.lefthalf.filled",
                action: .destination(.appearanceMode),
                keywords: ["light", "dark", "system"],
                isSuggested: false
            ),
            .init(
                id: "background-effect",
                title: String(localized: "Background Effect"),
                subtitle: String(localized: "Appearance"),
                systemImage: "sparkles",
                action: .destination(.backgroundEffect),
                keywords: ["effects", "wallpaper", "visuals"],
                isSuggested: false
            ),
            .init(
                id: "custom-shaders",
                title: String(localized: "Custom Shaders"),
                subtitle: String(localized: "Appearance"),
                systemImage: "cpu",
                action: .destination(.customShaders),
                keywords: ["shader", "graphics", "metal"],
                isSuggested: false
            ),
            .init(
                id: "window",
                title: String(localized: "Window"),
                subtitle: String(localized: "Appearance"),
                systemImage: "macwindow",
                action: .destination(.window),
                keywords: ["tab bar", "group menu", "project switcher", "layout", "display", "brightness", "hdr", "edr", "boost", "dynamic range", "selection", "loupe", "magnifier", "native"],
                isSuggested: false
            ),
            .init(
                id: "battery",
                title: String(localized: "Battery"),
                subtitle: String(localized: "Appearance"),
                systemImage: "battery.25percent",
                action: .destination(.battery),
                keywords: ["power", "refresh", "fps", "hz", "thermal", "saver", "low power", "promotion",
                           "adaptive", "charging", "plugged", "power source", "battery power", "wall power"],
                isSuggested: false
            ),

            .init(
                id: "keyboard-shortcuts",
                title: String(localized: "Keyboard Shortcuts"),
                subtitle: String(localized: "Terminal"),
                systemImage: "command",
                action: .destination(.keyboardShortcuts),
                keywords: ["keybinds", "hotkeys"],
                isSuggested: true
            ),
            .init(
                id: "mod-tap",
                title: String(localized: "Mod-Tap Keys"),
                subtitle: String(localized: "Terminal"),
                systemImage: "hand.tap",
                action: .destination(.modTap),
                keywords: ["caps lock", "modifier", "tap hold"],
                isSuggested: false
            ),
            .init(
                id: "terminal-writing-assistance",
                title: String(localized: "Writing Assistance"),
                subtitle: String(localized: "Terminal"),
                systemImage: TerminalWritingAssistanceMode.toolbarIcon,
                action: .section(.terminal),
                keywords: ["keyboard", "typing", "suggestions", "autocorrect", "autocorrection",
                           "spell checking", "spellcheck", "spelling", "completion", "software keyboard"],
                isSuggested: false
            ),
            .init(
                id: "option-key-as-alt",
                title: String(localized: "Option Key as Alt"),
                subtitle: String(localized: "Terminal"),
                systemImage: "option",
                action: .section(.terminal),
                keywords: ["meta", "modifier", "keyboard"],
                isSuggested: false
            ),
            .init(
                id: "restore-sessions",
                title: String(localized: "Restore Sessions on Launch"),
                subtitle: String(localized: "Terminal"),
                systemImage: "arrow.counterclockwise",
                action: .section(.terminal),
                keywords: ["session restore", "startup"],
                isSuggested: true
            ),
            .init(
                id: "persist-scrollback",
                title: String(localized: "Persist Scrollback History"),
                subtitle: String(localized: "Terminal"),
                systemImage: "clock.arrow.circlepath",
                action: .section(.terminal),
                keywords: ["history", "scrollback", "logs"],
                isSuggested: false
            ),
            .init(
                id: "background-session-keepalive",
                title: String(localized: "Keep TCP SSH Alive in Background"),
                subtitle: String(localized: "SSH Transport"),
                systemImage: "bolt.horizontal",
                action: .destination(.sshTransport),
                keywords: ["background", "battery", "keepalive", "tcp", "ssh", "tssh", "mosh", "connections"],
                isSuggested: false
            ),
            .init(
                id: "locale",
                title: String(localized: "Locale"),
                subtitle: String(localized: "Terminal"),
                systemImage: "globe",
                action: .destination(.locale),
                keywords: ["lang", "language", "environment"],
                isSuggested: false
            ),
            .init(
                id: "terminal-type",
                title: String(localized: "Terminal Type"),
                subtitle: String(localized: "Terminal"),
                systemImage: "character.cursor.ibeam",
                action: .destination(.terminalType),
                keywords: ["term", "terminfo", "xterm", "xterm-ghostty", "xterm-256color", "environment"],
                isSuggested: false
            ),
            .init(
                id: "ip-geolocation",
                title: String(localized: "IP Geolocation"),
                subtitle: String(localized: "Terminal"),
                systemImage: "location",
                action: .destination(.ipGeolocation),
                keywords: ["geo", "location provider"],
                isSuggested: false
            ),

            .init(
                id: "ssh-keys",
                title: String(localized: "SSH Keys"),
                subtitle: String(localized: "Connections"),
                systemImage: "key",
                action: .destination(.sshKeys),
                keywords: ["public key", "private key", "agent"],
                isSuggested: true
            ),
            .init(
                id: "saved-passwords",
                title: String(localized: "Saved Passwords"),
                subtitle: String(localized: "Connections"),
                systemImage: "lock",
                action: .destination(.savedPasswords),
                keywords: ["credentials", "keychain"],
                isSuggested: false
            ),
            .init(
                id: "known-hosts",
                title: String(localized: "Known Hosts"),
                subtitle: String(localized: "Connections"),
                systemImage: "checkmark.shield",
                action: .destination(.knownHosts),
                keywords: ["fingerprints", "host keys"],
                isSuggested: false
            ),
            .init(
                id: "host-certificate-authorities",
                title: String(localized: "Certificate Authorities"),
                subtitle: String(localized: "Connections"),
                systemImage: "checkmark.seal",
                action: .destination(.hostCertificateAuthorities),
                keywords: ["ca", "host certificate", "cert-authority", "openssh certificate", "trusted ca", "signed host key"],
                isSuggested: false
            ),
            .init(
                id: "ssh-shortcuts",
                title: String(localized: "SSH Shortcuts"),
                subtitle: String(localized: "Connections"),
                systemImage: "bolt.horizontal",
                action: .destination(.sshShortcuts),
                keywords: ["hss", "host shorthand", "patterns"],
                isSuggested: false
            ),
            .init(
                id: "openssh-import",
                title: String(localized: "Import from OpenSSH"),
                subtitle: String(localized: "Connections"),
                systemImage: "key.horizontal",
                action: .destination(.openSSHImport),
                keywords: ["ssh config", "ssh_config", "import", "migrate", ".ssh", "identityfile", "openssh", "hosts"],
                isSuggested: false
            ),
            .init(
                id: "ghostty-config-import",
                title: String(localized: "Import from Ghostty Config"),
                subtitle: String(localized: "Appearance"),
                systemImage: "square.and.arrow.down.on.square",
                action: .destination(.ghosttyConfigImport),
                keywords: ["ghostty", "config", "import", "migrate", "theme", "font", "keybinds", "palette"],
                isSuggested: false
            ),
            .init(
                id: "cloud-providers",
                title: String(localized: "Cloud Providers"),
                subtitle: String(localized: "Connections"),
                systemImage: "cloud",
                action: .destination(.cloudProviders),
                keywords: ["aws", "azure", "digitalocean", "linode"],
                isSuggested: false
            ),
            .init(
                id: "wifi-ap-providers",
                title: String(localized: "WiFi AP Providers"),
                subtitle: String(localized: "Connections"),
                systemImage: "wifi.router",
                action: .destination(.wifiAPProviders),
                keywords: ["wireless", "access point"],
                isSuggested: false
            ),
            .init(
                id: "kubernetes-clusters",
                title: String(localized: "Kubernetes Clusters"),
                subtitle: String(localized: "Connections"),
                systemImage: "helm",
                action: .destination(.kubernetesClusters),
                keywords: ["k8s", "kubectl", "clusters"],
                isSuggested: false
            ),
            .init(
                id: "background-tunnels",
                title: String(localized: "Background Tunnels"),
                subtitle: String(localized: "Connections"),
                systemImage: "arrow.triangle.swap",
                action: .destination(.backgroundTunnels),
                keywords: ["port forwarding", "tunnels"],
                isSuggested: false
            ),
            .init(
                id: "vpn",
                title: String(localized: "VPN"),
                subtitle: String(localized: "Connections"),
                systemImage: "network.badge.shield.half.filled",
                action: .destination(.vpn),
                keywords: ["networking", "tunnel", "wireguard"],
                isSuggested: true
            ),
            .init(
                id: "roam",
                title: String(localized: "Roam"),
                subtitle: String(localized: "Connections"),
                systemImage: "antenna.radiowaves.left.and.right",
                action: .destination(.roam),
                keywords: ["mobility", "handoff", "mosh"],
                isSuggested: false
            ),
            .init(
                id: "screen-sharing",
                title: String(localized: "Screen Sharing"),
                subtitle: String(localized: "Connections"),
                systemImage: "display.2",
                action: .destination(.screenSharing),
                keywords: ["vnc", "remote desktop", "clipboard", "panning", "pointer", "encryption", "tunnel"],
                isSuggested: false
            ),
            .init(
                id: "screen-sharing-clipboard",
                title: String(localized: "Default Clipboard Sync"),
                subtitle: String(localized: "Screen Sharing"),
                systemImage: "arrow.triangle.2.circlepath",
                action: .destination(.screenSharing),
                keywords: ["shared clipboard", "copy", "paste", "auto", "secure", "always on", "off"],
                isSuggested: false
            ),
            .init(
                id: "screen-sharing-panning",
                title: String(localized: "Screen Panning"),
                subtitle: String(localized: "Screen Sharing"),
                systemImage: "cursorarrow.motionlines",
                action: .destination(.screenSharing),
                keywords: [
                    "pointer", "edge", "continuous", "pan", "viewport",
                    "default mode", "when pointer reaches edge", "continuously with pointer",
                ],
                isSuggested: false
            ),
            .init(
                id: "ssh-transport",
                title: String(localized: "SSH Transport"),
                subtitle: String(localized: "Connections"),
                systemImage: "shield.lefthalf.filled",
                action: .destination(.sshTransport),
                keywords: ["ssh", "transport", "health", "probe", "post-quantum", "kex"],
                isSuggested: false
            ),
            .init(
                id: "connection-health",
                title: String(localized: "Connection Health Monitoring"),
                subtitle: String(localized: "SSH Transport"),
                systemImage: "heart.text.square",
                action: .destination(.sshTransport),
                keywords: ["probe", "interval", "health", "keepalive", "ssh"],
                isSuggested: false
            ),
            .init(
                id: "probe-interval",
                title: String(localized: "Probe Interval"),
                subtitle: String(localized: "SSH Transport"),
                systemImage: "timer",
                action: .destination(.sshTransport),
                keywords: ["connection health", "monitoring", "keepalive", "ssh"],
                isSuggested: false
            ),
            .init(
                id: "post-quantum-warning",
                title: String(localized: "Post-Quantum Warning"),
                subtitle: String(localized: "SSH Transport"),
                systemImage: "shield.lefthalf.filled",
                action: .destination(.sshTransport),
                keywords: ["ssh", "pq", "kex", "key exchange", "security", "post quantum"],
                isSuggested: false
            ),
            .init(
                id: "multiplexers",
                title: String(localized: "Multiplexers"),
                subtitle: String(localized: "Connections"),
                systemImage: "rectangle.split.2x1",
                action: .destination(.multiplexers),
                keywords: ["session manager", "multiplexer", "tmux", "zellij"],
                isSuggested: false
            ),
            .init(
                id: "coding-agents",
                title: String(localized: "Coding Agents"),
                subtitle: String(localized: "Terminal"),
                systemImage: "sparkles.rectangle.stack",
                action: .destination(.codingAgents),
                keywords: ["agent", "claude code", "codex", "copilot", "cursor", "opencode", "detect", "inbox", "attention", "badge"],
                isSuggested: false
            ),
            .init(
                id: "agent-notifications",
                title: String(localized: "Agent Notifications"),
                subtitle: String(localized: "Terminal"),
                systemImage: "bell.and.waves.left.and.right",
                action: .destination(.codingAgents),
                keywords: ["agent", "notify", "banner", "blocked", "needs input", "done"],
                isSuggested: false
            ),
            .init(
                id: "push-notifications",
                title: String(localized: "Push Notifications"),
                subtitle: String(localized: "Notifications"),
                systemImage: "lock.shield",
                action: .destination(.pushNotifications),
                keywords: ["push", "apns", "hook", "claude code", "codex", "remote", "encrypted", "pair", "background"],
                isSuggested: false
            ),
            .init(
                id: "task-detection",
                title: String(localized: "Command Detection"),
                subtitle: String(localized: "Terminal"),
                systemImage: "clock.badge.checkmark",
                action: .destination(.taskDetection),
                keywords: ["command", "task", "long running", "sudo", "password", "prompt", "build", "test", "pytest", "cargo", "terraform", "rsync", "transfer", "detect"],
                isSuggested: false
            ),
            .init(
                id: "task-notifications",
                title: String(localized: "Command Notifications"),
                subtitle: String(localized: "Terminal"),
                systemImage: "bell.and.waves.left.and.right",
                action: .destination(.taskDetection),
                keywords: ["command", "notify", "banner", "waiting", "input", "finished", "failed"],
                isSuggested: false
            ),
            .init(
                id: "clear-connection-history",
                title: String(localized: "Clear Connection History"),
                subtitle: String(localized: "Connections"),
                systemImage: "trash",
                action: .section(.connections),
                keywords: ["history", "recent connections"],
                isSuggested: false
            ),

            .init(
                id: "ai-configuration",
                title: String(localized: "Configuration"),
                subtitle: String(localized: "AI Assistant"),
                systemImage: "gearshape",
                action: .destination(.aiConfiguration),
                keywords: ["providers", "api key", "models"],
                isSuggested: false
            ),
            .init(
                id: "ai-text-size",
                title: String(localized: "Text Size"),
                subtitle: String(localized: "AI Assistant"),
                systemImage: "textformat.size",
                action: .destination(.aiTextSize),
                keywords: ["font", "chat text"],
                isSuggested: false
            ),
            .init(
                id: "voice-agent",
                title: String(localized: "Voice Agent"),
                subtitle: String(localized: "AI Assistant"),
                systemImage: "waveform",
                action: .destination(.voiceAgent),
                keywords: ["voice", "gemini", "audio", "speech"],
                isSuggested: false
            ),
            .init(
                id: "mcp-server",
                title: String(localized: "MCP Server"),
                subtitle: String(localized: "AI Assistant"),
                systemImage: "server.rack",
                action: .destination(.mcpServer),
                keywords: ["tools", "server", "integration"],
                isSuggested: false
            ),

            .init(
                id: "icloud-sync",
                title: String(localized: "iCloud Sync"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "arrow.triangle.2.circlepath.icloud",
                action: .destination(.iCloudSync),
                keywords: ["sync", "cloudkit", "backup"],
                isSuggested: false
            ),
            .init(
                id: "synced-groups",
                title: String(localized: "Synced Groups"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "square.grid.2x2",
                action: .destination(.syncedGroups),
                keywords: ["sync", "group", "groups", "icloud", "pin", "local", "device"],
                isSuggested: false
            ),
            .init(
                id: "pinned-settings",
                title: String(localized: "Pinned Settings"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "pin",
                action: .destination(.pinnedSettings),
                keywords: ["pin", "pinned", "local", "device", "sync", "icloud"],
                isSuggested: false
            ),
            .init(
                id: "config-file",
                title: String(localized: "Config File"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "doc.text",
                action: .destination(.configFile),
                keywords: ["config", "dotfile", "text", "file", "ghostty", "rootshell.conf", "editor"],
                isSuggested: false
            ),
            .init(
                id: "location-diary-mode",
                title: String(localized: "Location Diary Mode"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "mappin.and.ellipse",
                action: .section(.privacyData),
                keywords: ["tracking", "location", "diary"],
                isSuggested: false
            ),
            .init(
                id: "view-diary",
                title: String(localized: "View Diary"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "book",
                action: .destination(.locationDiary),
                keywords: ["entries", "location history"],
                isSuggested: false
            ),
            .init(
                id: "clipboard-manager",
                title: String(localized: "Clipboard Manager"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "list.clipboard",
                action: .destination(.clipboardManager),
                keywords: ["clipboard", "history", "copy", "paste", "transform", "base64", "jwt"],
                isSuggested: false
            ),
            .init(
                id: "auto-redact",
                title: String(localized: "Auto-Redact"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "eye.slash",
                action: .destination(.autoRedact),
                keywords: ["redact", "privacy", "pii", "mask", "hide", "email", "name", "screenshot", "recording", "sensitive"],
                isSuggested: false
            ),

            .init(
                id: "terminal-notifications",
                title: String(localized: "Terminal Notifications"),
                subtitle: String(localized: "Notifications"),
                systemImage: "bell",
                action: .section(.notifications),
                keywords: ["osc", "alerts"],
                isSuggested: false
            ),
            .init(
                id: "bell-sound",
                title: String(localized: "Bell Sound"),
                subtitle: String(localized: "Notifications"),
                systemImage: "speaker.wave.2",
                action: .section(.notifications),
                keywords: ["audio", "alerts"],
                isSuggested: false
            ),
            .init(
                id: "notification-sound",
                title: String(localized: "Notification Sound"),
                subtitle: String(localized: "Notifications"),
                systemImage: "music.note",
                action: .section(.notifications),
                keywords: ["audio", "reminders"],
                isSuggested: false
            ),
            .init(
                id: "volume",
                title: String(localized: "Volume"),
                subtitle: String(localized: "Notifications"),
                systemImage: "speaker.wave.3",
                action: .section(.notifications),
                keywords: ["sound level", "bell volume"],
                isSuggested: false
            ),
            .init(
                id: "acknowledgements",
                title: String(localized: "Acknowledgements"),
                subtitle: String(localized: "About"),
                systemImage: "doc.text",
                action: .destination(.acknowledgements),
                keywords: ["licenses", "credits"],
                isSuggested: false
            )
        ]

        #if targetEnvironment(macCatalyst)
        entries.append(contentsOf: [
            .init(
                id: "transparency",
                title: String(localized: "Transparency"),
                subtitle: String(localized: "Appearance"),
                systemImage: "slider.horizontal.below.rectangle",
                action: .destination(.transparency),
                keywords: ["opacity", "blur", "glass"],
                isSuggested: false
            ),
            .init(
                id: "line-scrolling",
                title: String(localized: "Use Line Scrolling"),
                subtitle: String(localized: "Terminal"),
                systemImage: "line.3.horizontal",
                action: .section(.terminal),
                keywords: ["scroll", "pixel", "smooth", "line", "legacy"],
                isSuggested: false
            ),
            .init(
                id: "rubber-band-scrolling",
                title: String(localized: "Rubber Band Scrolling"),
                subtitle: String(localized: "Terminal"),
                systemImage: "arrow.up.arrow.down",
                action: .section(.terminal),
                keywords: ["scroll", "pixel", "smooth", "bounce", "rubber", "band"],
                isSuggested: false
            )
        ])
        #if STANDALONE
        entries.append(
            .init(
                id: "local-shell",
                title: String(localized: "Local Shell"),
                subtitle: String(localized: "Terminal"),
                systemImage: "apple.terminal",
                action: .destination(.localShell),
                keywords: ["shell", "zsh", "bash", "fish", "nushell", "nu", "command", "login shell"],
                isSuggested: false
            )
        )
        #endif
        #else
        entries.append(contentsOf: [
            .init(
                id: "toolbar-keys",
                title: String(localized: "Toolbar Keys"),
                subtitle: String(localized: "Terminal"),
                systemImage: "keyboard",
                action: .destination(.toolbarKeys),
                keywords: ["toolbar", "custom keys"],
                isSuggested: false
            ),
            .init(
                id: "prompt-username",
                title: String(localized: "Prompt & Username"),
                subtitle: String(localized: "Terminal"),
                systemImage: "person.text.rectangle",
                action: .destination(.promptAndUsername),
                keywords: ["starship", "username", "shell prompt"],
                isSuggested: false
            ),
            .init(
                id: "bookmarked-locations",
                title: String(localized: "Bookmarked Locations"),
                subtitle: String(localized: "Terminal"),
                systemImage: "bookmark",
                action: .destination(.bookmarkedLocations),
                keywords: ["bookmarks", "locations", "paths"],
                isSuggested: false
            ),
            .init(
                id: "scroll-mode",
                title: String(localized: "Scroll Mode"),
                subtitle: String(localized: "Terminal"),
                systemImage: "hand.draw",
                action: .section(.terminal),
                keywords: ["touch", "gesture", "selection"],
                isSuggested: false
            ),
            .init(
                id: "line-scrolling",
                title: String(localized: "Use Line Scrolling"),
                subtitle: String(localized: "Terminal"),
                systemImage: "line.3.horizontal",
                action: .section(.terminal),
                keywords: ["scroll", "pixel", "smooth", "line", "legacy"],
                isSuggested: false
            ),
            .init(
                id: "rubber-band-scrolling",
                title: String(localized: "Rubber Band Scrolling"),
                subtitle: String(localized: "Terminal"),
                systemImage: "arrow.up.arrow.down",
                action: .section(.terminal),
                keywords: ["scroll", "pixel", "smooth", "bounce", "rubber", "band"],
                isSuggested: false
            ),
            .init(
                id: "double-space-period",
                title: String(localized: "\"\u{200B}.\u{200B}\" Shortcut"),
                subtitle: String(localized: "Terminal"),
                systemImage: "character.cursor.ibeam",
                action: .section(.terminal),
                keywords: ["double", "space", "period", "shortcut", "keyboard"],
                isSuggested: false
            ),
            .init(
                id: "ssh-session-reminders",
                title: String(localized: "SSH Session Reminders"),
                subtitle: String(localized: "Notifications"),
                systemImage: "bell.badge",
                action: .section(.notifications),
                keywords: ["background", "reminders"],
                isSuggested: false
            )
        ])

        #if canImport(ActivityKit)
        entries.append(
            .init(
                id: "live-activity",
                title: String(localized: "Live Activity"),
                subtitle: String(localized: "Privacy & Data"),
                systemImage: "record.circle",
                action: .destination(.liveActivity),
                keywords: ["dynamic island", "activity"],
                isSuggested: false
            )
        )
        #endif
        #endif

        #if targetEnvironment(macCatalyst)
        entries.removeAll { $0.id == "terminal-writing-assistance" }
        #endif

        #if CHINA_BUILD
        // Strip AI Assistant search entries for China builds. We keep them in
        // the array literal above for code readability and filter here; the
        // Swift optimizer dead-strips the excluded entries in release builds.
        entries.removeAll { entry in
            if case .section(.aiAssistant) = entry.action { return true }
            if case .destination(let dest) = entry.action {
                switch dest {
                case .aiConfiguration, .aiTextSize, .voiceAgent, .mcpServer:
                    return true
                default:
                    return false
                }
            }
            return false
        }
        #endif

        #if targetEnvironment(macCatalyst) && !STANDALONE
        // On the sandboxed App Store build VPN can't be hosted on macOS, so
        // strip it from search. Standalone routes through the bundled native host.
        entries.removeAll { entry in
            if case .destination(.vpn) = entry.action { return true }
            return false
        }
        #endif

        #if targetEnvironment(macCatalyst) || os(visionOS)
        entries.removeAll { entry in
            entry.id == "background-session-keepalive"
        }
        #endif

        return entries
    }

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
}

struct SettingsHomeList: View {
    @Binding var showDebugSettings: Bool

    var body: some View {
        List {
            Section {
                ForEach(SettingsSection.allCases.filter {
                    guard $0 != .about else { return false }
                    #if CHINA_BUILD
                    if $0 == .aiAssistant { return false }
                    #endif
                    return true
                }) { section in
                    NavigationLink(value: section) {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: section.icon)
                            Text(section.title)
                        }
                    }
                    .themedRow()
                }
            }

            Section {
                VStack(spacing: 12) {
                    AnimatedAboutIcon(
                        onTap: {
                            if let url = URL(string: "https://www.rootshell.com") {
                                UIApplication.shared.open(url)
                            }
                        },
                        onLongPress: {
                            showDebugSettings = true
                        }
                    )

                    Text("Rootshell")
                        .font(.headline)

                    Text("Written by Kit Knox")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .themedRow()

                HStack(spacing: 12) {
                    SettingsIcon(systemName: "info.circle")
                    Text("Version")
                    Spacer()
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(version) (\(build))")
                        Text(BuildInfo.date)
                    }
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                    .textSelection(.enabled)
                }
                .themedRow()

                NavigationLink(value: SettingsSearchDestination.acknowledgements) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "doc.text")
                        Text("Acknowledgements")
                    }
                }
                .themedRow()
            } footer: {
                SettingsOpenSourceFooter()
            }
        }
        .themedList()
        // On the List, not in it: destinations registered inside lazy list
        // content aren't reliably picked up, and the debug screen is pushed by
        // the tap-count gesture above rather than by a visible row.
        .navigationDestination(isPresented: $showDebugSettings) {
            DebugSettingsView()
        }
    }
}

struct SettingsFloatingSearchChrome: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var isSearchFieldFocused: Bool

    @Binding var reservedHeight: CGFloat
    let onSelect: (SettingsSearchEntry) -> Void

    @State private var isPresented = false
    @State private var searchText = ""
    @State private var collapsedPillHeight: CGFloat = 0

    private var displayedEntries: [SettingsSearchEntry] {
        SettingsSearchEntry.filtered(for: searchText)
    }

    private var chromeHorizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? 20 : 16
    }

    private var panelBackground: some ShapeStyle {
        if let sheetThemeColors {
            return AnyShapeStyle(sheetThemeColors.rowBackground.opacity(0.97))
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    private var fieldBackground: Color {
        sheetThemeColors?.background.opacity(0.7) ?? Color(uiColor: .secondarySystemBackground)
    }

    private var borderColor: Color {
        sheetThemeColors == nil ? Color.white.opacity(0.2) : Color.primary.opacity(0.08)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if isPresented {
                    Color.black.opacity(sheetThemeColors == nil ? 0.14 : 0.24)
                        .ignoresSafeArea()
                        .onTapGesture {
                            dismissSearch()
                        }
                        .transition(.opacity)

                    expandedPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.horizontal, chromeHorizontalPadding)
                        .padding(.bottom, 12)
                } else {
                    collapsedPill
                        .frame(width: collapsedPillWidth(for: proxy.size.width))
                        .position(
                            x: proxy.size.width / 2,
                            y: collapsedPillCenterY(
                                containerHeight: proxy.size.height,
                                bottomSafeArea: proxy.safeAreaInsets.bottom
                            )
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
            .animation(.spring(response: 0.34, dampingFraction: 0.9), value: isPresented)
            .onAppear {
                updateReservedHeight(bottomSafeArea: proxy.safeAreaInsets.bottom)
            }
            .onChange(of: collapsedPillHeight) { _, _ in
                updateReservedHeight(bottomSafeArea: proxy.safeAreaInsets.bottom)
            }
            .onChange(of: isPresented) { _, _ in
                updateReservedHeight(bottomSafeArea: proxy.safeAreaInsets.bottom)
            }
        }
        .onChange(of: isPresented) { _, newValue in
            if newValue {
                DispatchQueue.main.async {
                    isSearchFieldFocused = true
                }
            } else {
                isSearchFieldFocused = false
                searchText = ""
            }
        }
    }

    private var collapsedPill: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Search Settings")
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(panelBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search Settings")
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SettingsFloatingSearchBarHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(SettingsFloatingSearchBarHeightPreferenceKey.self) { height in
            collapsedPillHeight = height
        }
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search settings", text: $searchText)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .focused($isSearchFieldFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            guard let firstEntry = displayedEntries.first else { return }
                            select(firstEntry)
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(fieldBackground, in: Capsule())

                Button("Cancel") {
                    dismissSearch()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Suggested" : "Results")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            if displayedEntries.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try a broader term like SSH, theme, VPN, or notifications.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(displayedEntries) { entry in
                            Button {
                                select(entry)
                            } label: {
                                HStack(spacing: 12) {
                                    SettingsIcon(systemName: entry.systemImage)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(entry.subtitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(fieldBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(16)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 24, y: 10)
    }

    private func dismissSearch() {
        isPresented = false
    }

    private func collapsedPillWidth(for containerWidth: CGFloat) -> CGFloat {
        max(0, min(containerWidth - (chromeHorizontalPadding * 2), 520))
    }

    private func collapsedPillBottomInset(for bottomSafeArea: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        return 8
        #else
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Hug the bottom more aggressively on iPhone while still staying visible.
            return max(2, bottomSafeArea - 32)
        } else {
            return bottomSafeArea > 0 ? max(8, bottomSafeArea - 12) : 8
        }
        #endif
    }

    private func collapsedPillCenterY(containerHeight: CGFloat, bottomSafeArea: CGFloat) -> CGFloat {
        let pillHeight = max(collapsedPillHeight, 1)
        let centerY = containerHeight - collapsedPillBottomInset(for: bottomSafeArea) - (pillHeight / 2)
        return min(max(pillHeight / 2, centerY), containerHeight - (pillHeight / 2))
    }

    private func updateReservedHeight(bottomSafeArea: CGFloat) {
        guard !isPresented else { return }
        let height = collapsedPillHeight + max(8, collapsedPillBottomInset(for: bottomSafeArea))
        if abs(reservedHeight - height) > 0.5 {
            reservedHeight = height
        }
    }

    private func select(_ entry: SettingsSearchEntry) {
        let selectedEntry = entry
        dismissSearch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            onSelect(selectedEntry)
        }
    }
}

private struct SettingsFloatingSearchBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@ViewBuilder
func settingsSearchDestinationView(for destination: SettingsSearchDestination) -> some View {
    switch destination {
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
        SettingsAppearanceSection()
        #endif
    case .window:
        WindowSettingsView()
    case .battery:
        BatterySettingsView()
    case .toolbarKeys:
        #if !targetEnvironment(macCatalyst)
        KeyboardToolbarSettingsView()
        #else
        SettingsTerminalSection()
        #endif
    case .keyboardShortcuts:
        KeyboardShortcutsSettingsView()
    case .modTap:
        ModTapSettingsView()
    case .promptAndUsername:
        #if !targetEnvironment(macCatalyst)
        PromptSettingsView()
        #else
        SettingsTerminalSection()
        #endif
    case .bookmarkedLocations:
        #if !targetEnvironment(macCatalyst)
        BookmarkedLocationsView()
        #else
        SettingsTerminalSection()
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
    case .savedPasswords:
        SavedPasswordsView()
    case .knownHosts:
        KnownHostsView()
    case .hostCertificateAuthorities:
        HostCertificateAuthoritiesView()
    case .sshShortcuts:
        HSSConfigSettingsView()
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
        MCPSettingsView()
    case .voiceAgent:
        #if !CHINA_BUILD
        VoiceAgentSettingsView()
        #else
        EmptyView()
        #endif
    case .iCloudSync:
        CloudSyncSettingsView()
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
        SettingsPrivacySection()
        #endif
    case .liveActivity:
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveActivitySettingsView()
        #else
        SettingsPrivacySection()
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

struct SettingsView: View {
    var initialDestination: SettingsDestination? = nil

    @Environment(\.dismiss) var dismiss
    @State private var navigationPath = NavigationPath()
    @State private var hasNavigatedToInitialDestination = false
    @State private var navigateToVPN = false

    @State private var showDebugSettings = false
    @State private var searchReservedHeight: CGFloat = 88

    private var showsRootSearch: Bool {
        navigationPath.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationStack(path: $navigationPath) {
                SettingsHomeList(showDebugSettings: $showDebugSettings)
                    .safeAreaInset(edge: .bottom) {
                        if showsRootSearch {
                            Color.clear.frame(height: searchReservedHeight)
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
                    .navigationDestination(for: SettingsSection.self) { section in
                        sectionDetail(for: section)
                    }
                    .navigationDestination(for: SettingsDestination.self) { destination in
                        switch destination {
                        case .vpn:
                            #if !CHINA_BUILD && (!targetEnvironment(macCatalyst) || STANDALONE)
                            VPNSettingsView()
                            #else
                            EmptyView()
                            #endif
                        }
                    }
                    .navigationDestination(for: SettingsSearchDestination.self) { destination in
                        settingsSearchDestinationView(for: destination)
                    }
                    .onAppear {
                        handleInitialDestination()
                    }
            }

            if showsRootSearch {
                SettingsFloatingSearchChrome(
                    reservedHeight: $searchReservedHeight,
                    onSelect: handleSearchSelection
                )
            }
        }
    }

    @ViewBuilder
    private func sectionDetail(for section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            SettingsAppearanceSection()
        case .terminal:
            SettingsTerminalSection()
        case .connections:
            SettingsConnectionsSection(navigateToVPN: $navigateToVPN)
        case .aiAssistant:
            SettingsAISection()
        case .privacyData:
            SettingsPrivacySection()
        case .notifications:
            SettingsNotificationsSection()
        case .about:
            SettingsAboutSection()
        }
    }

    private func handleInitialDestination() {
        guard let initialDestination, !hasNavigatedToInitialDestination else { return }
        hasNavigatedToInitialDestination = true
        // Delay navigation by one run loop tick so the NavigationStack
        // finishes its initial layout.
        DispatchQueue.main.async {
            switch initialDestination {
            case .vpn:
                navigationPath.append(SettingsSection.connections)
                // Second tick to push VPN after Connections is on the stack.
                DispatchQueue.main.async {
                    navigateToVPN = true
                }
            }
        }
    }

    private func handleSearchSelection(_ entry: SettingsSearchEntry) {
        switch entry.action {
        case .section(let section):
            navigationPath.append(section)
        case .destination(let destination):
            navigationPath.append(destination)
        }
    }
}

#Preview {
    SettingsView()
}
