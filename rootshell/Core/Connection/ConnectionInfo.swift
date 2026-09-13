//
//  ConnectionInfo.swift
//  rootshell
//
//  Unified connection info enum for the Connection Info sheet
//

import Foundation

/// Unified connection information across all session types
enum ConnectionInfo: Identifiable, Sendable {
    case local(shell: String, workingDirectory: String?, connectedAt: Date)
    case ssh(SSHConnectionInfo)
    case kubernetes(cluster: String, node: String, connectedAt: Date)
    case console(provider: String, instance: String, connectedAt: Date)
    case mosh(SSHConnectionInfo)
    case trzsz(SSHConnectionInfo, transportMode: String? = nil, transportRef: TSSHTransportRef? = nil)
    case vnc(VNCConnectionInfo)
    indirect case tmux(TmuxConnectionInfo, transport: ConnectionInfo?)
    indirect case herdr(HerdrConnectionInfo, transport: ConnectionInfo?)

    var id: String {
        switch self {
        case .tmux(let info, _):
            return "tmux-\(info.gatewayID)-\(info.controllerID?.uuidString ?? "pending")-\(info.windowID.map(String.init) ?? "gateway")-\(info.paneID.map(String.init) ?? "none")"
        case .herdr(let info, _):
            return "herdr-\(info.gatewayID)-\(info.controllerID?.uuidString ?? "pending")-\(info.tabID ?? "gateway")-\(info.terminalID ?? "none")"
        case .local: return "local"
        case .ssh(let info): return "ssh-\(info.host)-\(info.port)"
        case .kubernetes(let cluster, let node, _): return "k8s-\(cluster)-\(node)"
        case .console(let provider, let instance, _): return "console-\(provider)-\(instance)"
        case .mosh(let info): return "mosh-\(info.host)-\(info.port)"
        case .trzsz(let info, _, _): return "trzsz-\(info.host)-\(info.port)"
        case .vnc(let info): return "vnc-\(info.host)-\(info.port)"
        }
    }

    /// Display name for the connection type
    var typeName: String {
        switch self {
        case .tmux: return "tmux Control Mode"
        case .herdr: return "herdr Control Mode"
        case .local: return "Local Shell"
        case .ssh: return "SSH"
        case .kubernetes: return "Kubernetes"
        case .console: return "Console"
        case .mosh: return "Mosh"
        case .trzsz: return "Trzsz"
        case .vnc: return "VNC"
        }
    }

    /// The connection start time
    var connectedAt: Date {
        switch self {
        case .tmux(let info, let transport): return transport?.connectedAt ?? info.openedAt
        case .herdr(let info, let transport): return transport?.connectedAt ?? info.openedAt
        case .local(_, _, let date): return date
        case .ssh(let info): return info.connectedAt
        case .kubernetes(_, _, let date): return date
        case .console(_, _, let date): return date
        case .mosh(let info): return info.connectedAt
        case .trzsz(let info, _, _): return info.connectedAt
        case .vnc(let info): return info.connectedAt
        }
    }

    /// The actual transport beneath any multiplexer layer.
    var transportInfo: ConnectionInfo? {
        switch self {
        case .tmux(_, let transport), .herdr(_, let transport): return transport?.transportInfo
        default: return self
        }
    }

    /// User-entered or provider-supplied host suitable for clipboard actions.
    var copyableHostname: String? {
        switch self {
        case .tmux(_, let transport), .herdr(_, let transport): return transport?.copyableHostname
        case .ssh(let info), .mosh(let info), .trzsz(let info, _, _):
            return info.host
        case .vnc(let info):
            return info.host
        case .local, .kubernetes, .console:
            return nil
        }
    }

    /// Resolved address for live SSH-family sessions, when available.
    var copyableIPAddress: String? {
        switch self {
        case .tmux(_, let transport), .herdr(_, let transport): return transport?.copyableIPAddress
        case .ssh(let info), .mosh(let info), .trzsz(let info, _, _):
            return info.resolvedIP
        case .local, .kubernetes, .console, .vnc:
            return nil
        }
    }
}
