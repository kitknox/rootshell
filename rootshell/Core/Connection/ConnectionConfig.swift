//
//  ConnectionConfig.swift
//  rootshell
//
//  Unified connection configuration for terminal sessions
//

import Foundation

/// Unified connection configuration for terminal sessions
enum ConnectionConfig: Equatable {
    /// Local shell (ios_system on iOS, helper on Catalyst)
    /// workingDirectory: Initial CWD for the shell (nil = user's home directory)
    case local(workingDirectory: String? = nil)

    /// SSH connection to remote host
    case ssh(SSHConfig)

    /// Kubernetes node debug shell
    case kubernetes(KubernetesNodeShellConfig)

    /// Cloud console (LISH WebSocket)
    case console(ConsoleConfig)

    /// EC2 Serial Console (SSH with ephemeral keys)
    case ec2Console(EC2ConsoleConfig)

    /// Mosh connection (mobile shell over UDP)
    case mosh(MoshConfig)

    /// SSH session launched from local shell - returns to shell when complete
    /// shellWorkingDirectory: CWD of the local shell at launch time (for shell return)
    case shellLaunchedSSH(sshConfig: SSHConfig, shellWorkingDirectory: String?)

    /// Mosh session launched from local shell - returns to shell when complete
    /// shellWorkingDirectory: CWD of the local shell at launch time (for shell return)
    case shellLaunchedMosh(moshConfig: MoshConfig, shellWorkingDirectory: String?)

    /// trzsz-ssh connection (QUIC-based roaming)
    case trzsz(TrzszConfig)

    /// trzsz session launched from local shell - returns to shell when complete
    /// shellWorkingDirectory: CWD of the local shell at launch time (for shell return)
    case shellLaunchedTrzsz(trzszConfig: TrzszConfig, shellWorkingDirectory: String?)

    /// Trzsz session being received from another device via Continuity Handoff.
    /// `transferTicketID` keys into `TrzszTransferInbox` for the actual
    /// payload (credentials + scrollback). Once the receiving TerminalView
    /// has attached and consumed the inbox slot, the connectionConfig is
    /// replaced with a normal `.trzsz(...)` so subsequent splits/history
    /// behave like any other roam session.
    case trzszTransfer(transferTicketID: UUID, displayName: String, host: String)

    /// Screen Sharing / VNC session. Rendered by a VNC pane, not a terminal
    /// surface; each split gets an independent session from the same config.
    case vnc(VNCConnectionConfig)

    /// KVM over IP session (GL.iNet Comet and other kvmd devices), rendered
    /// by a KVM pane; each split gets an independent session.
    case kvm(KVMConnectionConfig)

    /// The underlying SSHConfig for connection types built on one. Used to
    /// derive a stable per-connection identity (user@host:port), e.g. for the
    /// tmux gateway's last-session-name persistence (TmuxGatewaySessionStore).
    var underlyingSSHConfig: SSHConfig? {
        switch self {
        case .ssh(let config):
            return config
        case .shellLaunchedSSH(let sshConfig, _):
            return sshConfig
        case .trzsz(let config):
            return config.sshConfig
        case .shellLaunchedTrzsz(let trzszConfig, _):
            return trzszConfig.sshConfig
        case .mosh(let config):
            return config.sshConfig
        case .shellLaunchedMosh(let moshConfig, _):
            return moshConfig.sshConfig
        case .local, .kubernetes, .console, .ec2Console, .trzszTransfer, .vnc, .kvm:
            return nil
        }
    }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .local:
            return String(localized: "Local Shell", comment: "Connection type: local terminal shell")
        case .ssh(let config):
            return config.displayName
        case .kubernetes(let config):
            return config.displayName
        case .console(let config):
            return config.displayName
        case .ec2Console(let config):
            return config.displayName
        case .mosh(let config):
            return config.displayName
        case .trzsz(let config):
            return config.displayName
        case .shellLaunchedSSH(let sshConfig, _):
            return sshConfig.displayName
        case .shellLaunchedMosh(let moshConfig, _):
            return moshConfig.displayName
        case .shellLaunchedTrzsz(let trzszConfig, _):
            return trzszConfig.displayName
        case .trzszTransfer(_, let displayName, _):
            return displayName
        case .vnc(let config):
            return "Screen Sharing — \(config.displayName)"
        case .kvm(let config):
            return "KVM — \(config.displayName)"
        }
    }

    /// `displayName` without the "roam" decoration roaming transports add;
    /// for places that name the host rather than the transport.
    var hostDisplayName: String {
        switch self {
        case .mosh(let mosh), .shellLaunchedMosh(let mosh, _):
            return mosh.sshConfig.displayName
        case .trzsz(let trzsz), .shellLaunchedTrzsz(let trzsz, _):
            return trzsz.sshConfig.displayName
        default:
            return displayName
        }
    }

    var lifecycleDebugKind: String {
        switch self {
        case .local:
            return "local"
        case .ssh:
            return "ssh"
        case .kubernetes:
            return "kubernetes"
        case .console:
            return "console"
        case .ec2Console:
            return "ec2Console"
        case .mosh:
            return "mosh"
        case .shellLaunchedSSH:
            return "shellLaunchedSSH"
        case .shellLaunchedMosh:
            return "shellLaunchedMosh"
        case .trzsz:
            return "trzsz"
        case .shellLaunchedTrzsz:
            return "shellLaunchedTrzsz"
        case .trzszTransfer:
            return "trzszTransfer"
        case .vnc:
            return "vnc"
        case .kvm:
            return "kvm"
        }
    }

    /// Whether this requires SSH callbacks (auth, host key validation)
    var requiresSSHCallbacks: Bool {
        switch self {
        case .ssh, .shellLaunchedSSH:
            return true
        case .mosh, .shellLaunchedMosh:
            return true  // Mosh uses SSH for server spawn
        case .trzsz, .shellLaunchedTrzsz:
            return true  // trzsz uses SSH for server spawn
        case .trzszTransfer:
            return false  // attaches via stored credentials, no SSH spawn
        case .vnc(let config):
            // Only when the transport jumps through SSH (host keys, auth)
            if case .none = config.effectiveJump { return false }
            return true
        case .kvm(let config):
            if case .none = config.jump { return false }
            return true
        default:
            return false
        }
    }

    // MARK: - Convenience Extractors

    /// Extract SSH config if this is an SSH connection
    var sshConfig: SSHConfig? {
        switch self {
        case .ssh(let config): return config
        case .shellLaunchedSSH(let config, _): return config
        default: return nil
        }
    }

    /// Extract Kubernetes config if this is a Kubernetes connection
    var kubernetesConfig: KubernetesNodeShellConfig? {
        if case .kubernetes(let config) = self { return config }
        return nil
    }

    /// Extract console config if this is a console connection
    var consoleConfig: ConsoleConfig? {
        if case .console(let config) = self { return config }
        return nil
    }

    /// Extract EC2 console config if this is an EC2 console connection
    var ec2ConsoleConfig: EC2ConsoleConfig? {
        if case .ec2Console(let config) = self { return config }
        return nil
    }

    /// Extract mosh config if this is a mosh connection
    var moshConfig: MoshConfig? {
        switch self {
        case .mosh(let config): return config
        case .shellLaunchedMosh(let config, _): return config
        default: return nil
        }
    }

    /// Extract trzsz config if this is a trzsz connection
    var trzszConfig: TrzszConfig? {
        switch self {
        case .trzsz(let config): return config
        case .shellLaunchedTrzsz(let config, _): return config
        default: return nil
        }
    }

    /// Extract VNC config if this is a Screen Sharing connection
    var vncConfig: VNCConnectionConfig? {
        if case .vnc(let config) = self { return config }
        return nil
    }

    /// Extract SSH config from SSH, Mosh, or trzsz connections (for history recording)
    var sshConfigForHistory: SSHConfig? {
        switch self {
        case .ssh(let config): return config
        case .mosh(let moshConfig): return moshConfig.sshConfig
        case .trzsz(let trzszConfig): return trzszConfig.sshConfig
        case .shellLaunchedSSH(let config, _): return config
        case .shellLaunchedMosh(let moshConfig, _): return moshConfig.sshConfig
        case .shellLaunchedTrzsz(let trzszConfig, _): return trzszConfig.sshConfig
        default: return nil
        }
    }

    /// Whether this is a Mosh connection
    var isMosh: Bool {
        switch self {
        case .mosh, .shellLaunchedMosh: return true
        default: return false
        }
    }

    /// Whether this is a trzsz connection
    var isTrzsz: Bool {
        switch self {
        case .trzsz, .shellLaunchedTrzsz, .trzszTransfer: return true
        default: return false
        }
    }

    /// Whether this is a Roam connection (mosh or trzsz)
    var isRoam: Bool {
        isMosh || isTrzsz
    }

    /// Extract working directory for local shell connections
    var workingDirectory: String? {
        if case .local(let cwd) = self { return cwd }
        return nil
    }

    // MARK: - Shell-Launched Support

    /// Whether this is a session launched from a local shell
    var isShellLaunched: Bool {
        switch self {
        case .shellLaunchedSSH, .shellLaunchedMosh, .shellLaunchedTrzsz: return true
        default: return false
        }
    }

    /// Extract shell working directory for shell-launched connections
    var shellWorkingDirectory: String? {
        switch self {
        case .shellLaunchedSSH(_, let cwd): return cwd
        case .shellLaunchedMosh(_, let cwd): return cwd
        case .shellLaunchedTrzsz(_, let cwd): return cwd
        default: return nil
        }
    }

    /// Returns the inner connection config (unwrapping shell-launched wrapper)
    /// For regular configs, returns self unchanged.
    var unwrappedConfig: ConnectionConfig {
        switch self {
        case .shellLaunchedSSH(let config, _): return .ssh(config)
        case .shellLaunchedMosh(let config, _): return .mosh(config)
        case .shellLaunchedTrzsz(let config, _): return .trzsz(config)
        default: return self
        }
    }

    // MARK: - Split Support

    /// Creates a connection config suitable for a new split.
    /// - For local shells: preserves working directory
    /// - For SSH: returns the same config (each connection is independent)
    /// - For Kubernetes: creates a new session ID (each pod must be unique)
    /// - For shell-launched: preserves shell context for new split
    func forNewSplit() -> ConnectionConfig {
        switch self {
        case .local(let cwd):
            // Preserve working directory when creating splits
            return .local(workingDirectory: cwd)
        case .ssh(let config):
            // SSH connections can reuse the same config - each creates an independent connection
            return .ssh(config)
        case .kubernetes(let config):
            // Kubernetes needs a fresh session ID to create a new unique pod
            return .kubernetes(config.withNewSession())
        case .console(let config):
            // Console needs a fresh session ID for a new WebSocket connection
            return .console(config.withNewSession())
        case .ec2Console(let config):
            // EC2 console needs a fresh session ID for a new SSH connection
            return .ec2Console(config.withNewSession())
        case .mosh(let config):
            // Mosh connections can reuse the same config - each creates independent session
            return .mosh(config.forNewSplit())
        case .trzsz(let config):
            // trzsz connections can reuse the same config - each creates independent session
            return .trzsz(config.forNewSplit())
        case .shellLaunchedSSH(let sshConfig, let shellCwd):
            // Preserve shell context for new split
            return .shellLaunchedSSH(sshConfig: sshConfig, shellWorkingDirectory: shellCwd)
        case .shellLaunchedMosh(let moshConfig, let shellCwd):
            // Preserve shell context for new split
            return .shellLaunchedMosh(moshConfig: moshConfig.forNewSplit(), shellWorkingDirectory: shellCwd)
        case .shellLaunchedTrzsz(let trzszConfig, let shellCwd):
            // Preserve shell context for new split
            return .shellLaunchedTrzsz(trzszConfig: trzszConfig.forNewSplit(), shellWorkingDirectory: shellCwd)
        case .trzszTransfer:
            // A transfer is single-shot; once attached the config gets
            // rewritten to .trzsz(...) by setupPTYAndShell. Splits taken
            // before that rewrite happens have nothing useful to inherit,
            // so fall back to a local shell — the user can launch tssh
            // again from there if they want a parallel session.
            return .local(workingDirectory: nil)
        case .vnc(let config):
            // Each split opens an independent VNC session from the same config
            return .vnc(config)
        case .kvm(let config):
            return .kvm(config)
        }
    }
}

// MARK: - Open in Folder

/// How well "start in directory" can be honoured for a new pane on a target.
enum InitialDirectorySupport: Equatable {
    case full
    /// Honoured when the multiplexer session is created, not when attaching.
    case onCreateOnly(multiplexer: String)
    case unsupported
}

extension ConnectionConfig {
    /// Config for a NEW pane on the same target that starts in `directory`
    /// (absolute, on the target's filesystem). Call on `forNewSplit()` output.
    /// nil for targets that cannot honour a start directory.
    func startingIn(directory: String) -> ConnectionConfig? {
        switch self {
        case .local:
            return .local(workingDirectory: directory)
        case .ssh(var config):
            config.initialDirectory = directory
            return .ssh(config)
        case .mosh(var config):
            config.sshConfig.initialDirectory = directory
            return .mosh(config)
        case .trzsz(var config):
            config.sshConfig.initialDirectory = directory
            return .trzsz(config)
        case .shellLaunchedSSH(var config, let shellCwd):
            config.initialDirectory = directory
            return .shellLaunchedSSH(sshConfig: config, shellWorkingDirectory: shellCwd)
        case .shellLaunchedMosh(var config, let shellCwd):
            config.sshConfig.initialDirectory = directory
            return .shellLaunchedMosh(moshConfig: config, shellWorkingDirectory: shellCwd)
        case .shellLaunchedTrzsz(var config, let shellCwd):
            config.sshConfig.initialDirectory = directory
            return .shellLaunchedTrzsz(trzszConfig: config, shellWorkingDirectory: shellCwd)
        case .kubernetes, .console, .ec2Console, .trzszTransfer, .vnc, .kvm:
            return nil
        }
    }

    var initialDirectorySupport: InitialDirectorySupport {
        switch self {
        case .local:
            return .full
        case .kubernetes, .console, .ec2Console, .trzszTransfer, .vnc, .kvm:
            return .unsupported
        default:
            guard let ssh = underlyingSSHConfig else { return .unsupported }
            if let command = ssh.remoteCommand, !command.isEmpty { return .full }
            if ssh.launchCommandMode == .initialCommandWithPTY, let command = ssh.launchCommand, !command.isEmpty {
                return .full
            }
            if ssh.tmuxAutoEnable { return .onCreateOnly(multiplexer: "tmux") }
            if ssh.herdrAutoEnable && !ssh.herdrControlModeEnabled { return .onCreateOnly(multiplexer: "herdr") }
            if ssh.zmxAutoEnable { return .onCreateOnly(multiplexer: "zmx") }
            return .full
        }
    }
}
