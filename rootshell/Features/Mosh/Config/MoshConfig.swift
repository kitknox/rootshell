//
//  MoshConfig.swift
//  rootshell
//
//  Configuration for Mosh (mobile shell) connections
//

import Foundation

/// Configuration for a Mosh connection
/// Mosh provides robust mobile terminal connections that survive network changes
/// and high latency through its State Synchronization Protocol (SSP) over UDP.
struct MoshConfig: Codable, Hashable, Sendable {
    // MARK: - UserDefaults Keys

    /// UserDefaults key for default prediction mode setting
    static let defaultPredictionModeKey = "roamDefaultPredictionMode"

    /// UserDefaults key for whether predictions overwrite existing cells instead of inserting.
    static let defaultPredictOverwriteKey = "roamDefaultPredictOverwrite"

    /// UserDefaults key for whether the mosh renderer should enter the
    /// alternate screen on session open (defaults to true when unset).
    static let altScreenEnabledKey = "roamMoshAltScreenEnabled"

    /// Reads the current alt-screen preference, defaulting to true when the
    /// key has never been written. Used by `VTDisplayRenderer` at session
    /// open and close so a toggle in Roam settings takes effect on the next
    /// mosh connection without any restart.
    static var altScreenEnabled: Bool {
        SettingsStore.shared.value(Settings.Roam.moshAltScreen)
    }

    /// Reads the default overwrite-prediction preference for newly created sessions.
    static var defaultPredictOverwrite: Bool {
        SettingsStore.shared.value(Settings.Roam.predictOverwrite)
    }

    // MARK: - SSH Configuration

    /// SSH configuration for initial server spawn
    /// Mosh uses SSH to authenticate and start mosh-server
    var sshConfig: SSHConfig

    // MARK: - UDP Settings

    /// Minimum UDP port for mosh-server (default: 60000)
    var udpPortMin: Int

    /// Maximum UDP port for mosh-server (default: 61000)
    var udpPortMax: Int

    /// UDP port range for mosh-server
    var udpPortRange: ClosedRange<Int> {
        udpPortMin...udpPortMax
    }

    // MARK: - Prediction Settings

    /// Prediction mode for local echo
    var predictionMode: PredictionMode

    /// Whether local predictions replace the current cell instead of shifting the row.
    var predictOverwrite: Bool

    /// Prediction display mode
    nonisolated enum PredictionMode: String, Codable, Sendable, CaseIterable {
        /// Always show local echo predictions
        case always
        /// Show predictions only when network is slow (adaptive)
        case adaptive
        /// Never show local echo predictions
        case never

        var displayName: String {
            switch self {
            case .always: return String(localized: "Always", comment: "Prediction mode: always show predictions")
            case .adaptive: return String(localized: "Adaptive", comment: "Prediction mode: show predictions when network is slow")
            case .never: return String(localized: "Never", comment: "Prediction mode: never show predictions")
            }
        }
    }

    // MARK: - Terminal Settings

    /// Request specific colors from server (default: 256)
    var colors: Int

    /// Custom mosh-server path (nil = use default "mosh-server")
    var serverPath: String?

    /// Additional arguments to pass to mosh-server
    var serverArgs: [String]

    // MARK: - Hole-Punch Configuration

    /// Configuration for UDP hole-punching to traverse restrictive firewalls
    /// Hole-punching is useful when servers have stateful firewalls that block
    /// incoming UDP but allow all outgoing traffic.
    var holePunchConfig: HolePunchConfig

    // MARK: - Initialization

    /// Creates a new Mosh configuration
    /// - Parameters:
    ///   - sshConfig: SSH configuration for server spawn
    ///   - udpPortMin: Minimum UDP port (default: 60000)
    ///   - udpPortMax: Maximum UDP port (default: 61000)
    ///   - predictionMode: Prediction mode (default: .adaptive)
    ///   - predictOverwrite: Whether predictions overwrite existing cells (default: Roam setting)
    ///   - colors: Number of colors (default: 256)
    ///   - serverPath: Custom mosh-server path (default: nil)
    ///   - serverArgs: Additional server arguments (default: empty)
    ///   - holePunchConfig: Hole-punch configuration (default: reads from UserDefaults)
    init(
        sshConfig: SSHConfig,
        udpPortMin: Int = 60000,
        udpPortMax: Int = 61000,
        predictionMode: PredictionMode = .adaptive,  // Adaptive: show predictions only when network is slow
        predictOverwrite: Bool? = nil,
        colors: Int = 256,
        serverPath: String? = nil,
        serverArgs: [String] = [],
        holePunchConfig: HolePunchConfig? = nil
    ) {
        self.sshConfig = sshConfig
        self.udpPortMin = udpPortMin
        self.udpPortMax = udpPortMax
        self.predictionMode = predictionMode
        self.predictOverwrite = predictOverwrite ?? Self.defaultPredictOverwrite
        self.colors = colors
        self.serverPath = serverPath
        self.serverArgs = serverArgs

        // Use provided config, or create default with UserDefaults-based enabled state
        if let config = holePunchConfig {
            self.holePunchConfig = config
        } else {
            let roamEnabled = SettingsStore.shared.value(Settings.Roam.holePunch)
            self.holePunchConfig = HolePunchConfig(enabled: roamEnabled)
        }
    }

    /// Backward-compatible decoding for configs written before overwrite prediction existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sshConfig = try container.decode(SSHConfig.self, forKey: .sshConfig)
        udpPortMin = try container.decode(Int.self, forKey: .udpPortMin)
        udpPortMax = try container.decode(Int.self, forKey: .udpPortMax)
        predictionMode = try container.decode(PredictionMode.self, forKey: .predictionMode)
        predictOverwrite = try container.decodeIfPresent(Bool.self, forKey: .predictOverwrite) ?? false
        colors = try container.decode(Int.self, forKey: .colors)
        serverPath = try container.decodeIfPresent(String.self, forKey: .serverPath)
        serverArgs = try container.decode([String].self, forKey: .serverArgs)
        holePunchConfig = try container.decode(HolePunchConfig.self, forKey: .holePunchConfig)
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

    /// Generates the mosh-server command to execute via SSH
    ///
    /// Format: export LANG=<locale>; [ "$(locale charmap 2>/dev/null)" = "UTF-8" ] || export LANG=C.UTF-8; mosh-server new [-s] -p <port>:<port> -c <colors> -- <shell>
    ///
    /// Options:
    /// - `-s` (no argument): bind to the SSH connection's interface (SSH_CONNECTION env var)
    /// - `-i IP`: bind to specific IP address (0.0.0.0 for all IPv4, :: for all IPv6)
    ///
    /// We use `-s` to bind to the same interface the SSH connection came in on,
    /// which is the most reliable approach for multihomed hosts.
    ///
    /// The locale is set with a fallback mechanism:
    /// 1. Export user's preferred locale (e.g., en_GB.UTF-8)
    /// 2. Check if `locale charmap` returns exactly "UTF-8"
    /// 3. If not (returns ANSI_X3.4-1968 or POSIX for invalid locales), fall back to C.UTF-8
    ///
    /// We check the charmap value rather than the exit code because `locale charmap`
    /// returns 0 even for invalid locales on many systems - it just outputs ASCII charset.
    ///
    /// - Parameter shell: The shell to run (default: $SHELL)
    func serverCommand(shell: String = "$SHELL") -> String {
        // Set LANG with fallback: check if locale charmap is UTF-8, else use C.UTF-8
        // mosh-server requires a valid UTF-8 locale to start
        var cmd = SSHConfig.remoteExecPathPrefix
        if let preferredLocale = LocaleHelper.effectiveLocale {
            cmd += "export LANG=\(preferredLocale); [ \"$(locale charmap 2>/dev/null)\" = \"UTF-8\" ] || export LANG=C.UTF-8; "
        } else {
            // No locale override — ensure at least a UTF-8 locale for mosh-server
            cmd += "[ \"$(locale charmap 2>/dev/null)\" = \"UTF-8\" ] || export LANG=C.UTF-8; "
        }
        cmd += "exec "
        cmd += serverPath ?? "mosh-server"
        cmd += " new"

        // Use -s to bind to the SSH connection's interface
        // This is the most reliable approach - mosh-server reads SSH_CONNECTION
        // and binds to that interface, matching the address family of the SSH connection
        cmd += " -s"

        // Port range
        cmd += " -p \(udpPortMin):\(udpPortMax)"

        // Colors
        cmd += " -c \(colors)"

        // Additional arguments
        for arg in serverArgs {
            cmd += " \(arg)"
        }

        // Command to run inside mosh.
        cmd += " -- \(moshSessionCommandWithTerm)"

        return LoginShellCommand.runInPOSIXShell(cmd)
    }

    /// The post-`--` command, with `TERM` forced when the user asked for a value
    /// mosh-server would not produce on its own.
    ///
    /// mosh-server ignores both `export TERM=` in its own environment and
    /// `-l TERM=`: after forking it unconditionally runs
    /// `setenv("TERM", colors == 256 ? "xterm-256color" : "xterm", 1)` in the
    /// child (mosh-server.cc). The only place left to set it is inside the
    /// command mosh-server execs, so wrap that command when — and only when —
    /// the resolved value differs from what mosh-server would pick anyway.
    /// Leaving the default path unwrapped keeps the usual command line
    /// byte-identical to before.
    private var moshSessionCommandWithTerm: String {
        let sessionCommand = sshConfig.effectiveMoshSessionCommand
        let desired = sshConfig.effectiveTerminalType
        let moshDefault = colors == 256 ? "xterm-256color" : "xterm"
        guard desired != moshDefault else { return sessionCommand }

        // `desired` is validated as a terminfo name by TerminalTypeSettings, so
        // it needs no quoting. `exec` avoids leaving an extra shell in the tree.
        let inner = "export TERM=\(desired); exec \(sessionCommand)"
        return "sh -c \(SSHConfig.shellSingleQuote(inner))"
    }

    // MARK: - Split Support

    /// Creates a copy suitable for a new split terminal
    func forNewSplit() -> MoshConfig {
        // Mosh connections can reuse the same config - each creates independent session
        return self
    }
}
