//
//  TSSHConfig.swift
//  rootshell
//
//  Configuration for trzsz-ssh (tsshd) connections
//

import Foundation

/// Configuration for a trzsz-ssh connection
///
/// trzsz-ssh provides UDP-based terminal connections using QUIC (TLS 1.3)
/// or KCP (AES-GCM-256) transport with built-in NAT traversal.
///
/// KCP is the default as it provides lower latency which is ideal for
/// interactive terminal sessions. QUIC is available as an alternative with
/// better congestion control for high-throughput scenarios.
struct TrzszConfig: Codable, Hashable, Sendable {
    // MARK: - UserDefaults Keys

    /// UserDefaults key for the default UDP port minimum
    static let defaultUDPPortMinKey = "trzszDefaultUDPPortMin"

    /// UserDefaults key for the default UDP port maximum
    static let defaultUDPPortMaxKey = "trzszDefaultUDPPortMax"

    /// UserDefaults key for preserving typed input while tssh is roaming.
    static let keepPendingInputKey = "trzszKeepPendingInput"

    /// Whether typed input should be queued while tssh is disconnected.
    /// Defaults to false, matching upstream tsshd's conservative discard behavior.
    static var keepPendingInput: Bool {
        SettingsStore.shared.value(Settings.Roam.trzszKeepPendingInput)
    }

    /// The user's preferred minimum UDP port from settings (defaults to 61000)
    static var preferredUDPPortMin: Int {
        let value = SettingsStore.shared.value(Settings.Roam.trzszUDPPortMin)
        return value != 0 ? value : 61000
    }

    /// The user's preferred maximum UDP port from settings (defaults to 61999)
    static var preferredUDPPortMax: Int {
        let value = SettingsStore.shared.value(Settings.Roam.trzszUDPPortMax)
        return value != 0 ? value : 61999
    }

    // MARK: - SSH Configuration

    /// SSH configuration for initial server spawn
    /// Used to authenticate and start tsshd on the remote host
    var sshConfig: SSHConfig

    // MARK: - Transport Settings

    /// Transport mode for the connection
    var transportMode: TransportMode

    /// Transport protocol options
    nonisolated enum TransportMode: String, Codable, Sendable, CaseIterable {
        /// QUIC with TLS 1.3 (default - secure with good congestion control)
        case quic
        /// KCP with AES-GCM-256 (alternative - potentially lower latency)
        case kcp
        /// Auto-detect: try QUIC first, fall back to KCP
        case auto

        /// UserDefaults key for storing the default transport mode
        static let defaultTransportModeKey = "trzszDefaultTransportMode"

        /// The user's preferred transport mode from settings
        static var preferred: TransportMode {
            SettingsStore.shared.value(Settings.Roam.trzszTransportMode)
        }

        var displayName: String {
            switch self {
            case .quic: return String(localized: "QUIC", comment: "Transport mode: QUIC protocol")
            case .kcp: return String(localized: "KCP", comment: "Transport mode: KCP protocol")
            case .auto: return String(localized: "Auto", comment: "Transport mode: auto-detect protocol")
            }
        }

        var descriptionText: String {
            switch self {
            case .quic: return String(localized: "QUIC over TLS 1.3 - secure with good congestion control", comment: "QUIC transport mode description")
            case .kcp: return String(localized: "KCP over UDP - potentially lower latency", comment: "KCP transport mode description")
            case .auto: return String(localized: "Try QUIC first, fall back to KCP", comment: "Auto transport mode description")
            }
        }
    }

    // MARK: - UDP Settings

    /// Minimum UDP port for tsshd (default: 61000)
    var udpPortMin: Int

    /// Maximum UDP port for tsshd (default: 61999)
    var udpPortMax: Int

    /// UDP port range for tsshd
    var udpPortRange: ClosedRange<Int> {
        udpPortMin...udpPortMax
    }

    // MARK: - Server Settings

    /// Custom tsshd path (nil = use default "tsshd")
    var serverPath: String?

    /// Packet MTU for KCP/QUIC transport (0 = use default 1400).
    /// Both client and server must match.
    var mtu: Int

    /// Keep typed input queued while the transport is disconnected.
    var keepPendingInput: Bool

    private enum CodingKeys: String, CodingKey {
        case sshConfig
        case transportMode
        case udpPortMin
        case udpPortMax
        case serverPath
        case mtu
        case keepPendingInput
    }

    // MARK: - Initialization

    /// Creates a new trzsz-ssh configuration
    /// - Parameters:
    ///   - sshConfig: SSH configuration for server spawn
    ///   - transportMode: Transport protocol (default: .kcp)
    ///   - udpPortMin: Minimum UDP port (default: 61000)
    ///   - udpPortMax: Maximum UDP port (default: 61999)
    ///   - serverPath: Custom tsshd path (default: nil)
    ///   - mtu: Packet MTU for KCP/QUIC (0 = default 1400)
    init(
        sshConfig: SSHConfig,
        transportMode: TransportMode = .kcp,
        udpPortMin: Int = Self.preferredUDPPortMin,
        udpPortMax: Int = Self.preferredUDPPortMax,
        serverPath: String? = nil,
        mtu: Int = 0,
        keepPendingInput: Bool = Self.keepPendingInput
    ) {
        self.sshConfig = sshConfig
        self.transportMode = transportMode
        self.udpPortMin = udpPortMin
        self.udpPortMax = udpPortMax
        self.serverPath = serverPath
        self.mtu = mtu
        self.keepPendingInput = keepPendingInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sshConfig = try container.decode(SSHConfig.self, forKey: .sshConfig)
        transportMode = try container.decode(TransportMode.self, forKey: .transportMode)
        udpPortMin = try container.decode(Int.self, forKey: .udpPortMin)
        udpPortMax = try container.decode(Int.self, forKey: .udpPortMax)
        serverPath = try container.decodeIfPresent(String.self, forKey: .serverPath)
        mtu = try container.decodeIfPresent(Int.self, forKey: .mtu) ?? 0
        keepPendingInput = try container.decodeIfPresent(Bool.self, forKey: .keepPendingInput) ?? false
    }

    // MARK: - Display

    /// Display name for UI
    var displayName: String {
        "roam \(sshConfig.displayName)"
    }

    /// Host for display
    var host: String {
        sshConfig.host
    }

    /// Username for display
    var username: String {
        sshConfig.username
    }

    // MARK: - Server Command Generation

    /// Generates the tsshd command to execute via SSH
    ///
    /// Format: tsshd [--quic|--kcp] --port <port-range>
    ///
    /// Options:
    /// - `--quic`: Use QUIC transport (default)
    /// - `--kcp`: Use KCP transport
    /// - `--port <min>-<max>`: UDP port range
    ///
    /// The server outputs JSON with connection info to stdout.
    ///
    /// When no custom `serverPath` is set, the command prepends common Go binary
    /// locations to PATH. `go install` places binaries in `~/go/bin` by default,
    /// which is often not in PATH for non-login SSH shells.
    ///
    /// That PATH prefix is a POSIX-sh script (`VAR=`, `export`, `for`), but
    /// `sshd` runs exec-channel commands through the client's *login* shell
    /// (`$SHELL -c '<command>'`), which on fish or csh rejects that syntax
    /// outright. `RemoteLoginShell.wrapForLoginShell` routes it through `sh -c`
    /// so it runs the same on every login shell.
    func serverCommand() -> String {
        let binary = serverPath ?? "tsshd"

        var args = " --attachable --port \(udpPortMin)-\(udpPortMax)"

        if mtu > 0 {
            args += " --mtu \(mtu)"
        }

        switch transportMode {
        case .kcp, .auto:
            args += " --kcp"
        case .quic:
            args += " --quic"
        }

        if ResumeDebugLogger.shared.isEnabled {
            args += " --debug"
        }

        // When using the default binary name (no custom path), prepend common
        // Homebrew and Go install locations so tsshd is found in non-interactive
        // SSH exec shells. `exec` keeps the process tree the same depth as
        // before this fix (the login shell now execs `sh`, which execs tsshd
        // as the last command of its own `-c` string), so the SSH channel's
        // signals/EOF still reach tsshd directly rather than an intermediate
        // shell.
        if serverPath == nil {
            return RemoteLoginShell.wrapForLoginShell("\(SSHConfig.remoteExecPathPrefix)exec \(binary)\(args)")
        }

        return "\(binary)\(args)"
    }

    // MARK: - Split Support

    /// Creates a copy suitable for a new split terminal
    func forNewSplit() -> TrzszConfig {
        // trzsz connections can reuse the same config - each creates independent session
        return self
    }
}
