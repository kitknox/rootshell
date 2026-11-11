//
//  VPNError.swift
//  rootshell
//
//  Error types for VPN tunnel operations
//

import Foundation

/// Errors specific to VPN tunnel operations
enum VPNError: LocalizedError {
    case appGroupUnavailable
    case configSerializationFailed
    case configNotFound
    case tunnelAlreadyRunning
    case tunnelNotRunning
    case credentialAccessFailed(String)
    case sshConnectionFailed(String)
    case netstackFailed(String)
    case extensionNotInstalled
    case extensionStartFailed(String)
    case biometricAuthRequired
    case vpnKeyStoreFailed(String)
    case unsupportedTransport(String)
    case invalidControlURL

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return String(localized: "App group container is unavailable", comment: "VPN error: shared app group container could not be opened")
        case .configSerializationFailed:
            return String(localized: "Failed to serialize VPN configuration", comment: "VPN error: tunnel config could not be encoded")
        case .configNotFound:
            return String(localized: "VPN profile configuration was not found in shared storage", comment: "VPN error: no saved snapshot for the profile")
        case .tunnelAlreadyRunning:
            return String(localized: "VPN tunnel is already running", comment: "VPN error: a tunnel is already active")
        case .tunnelNotRunning:
            return String(localized: "VPN tunnel is not running", comment: "VPN error: no active tunnel to operate on")
        case .credentialAccessFailed(let detail):
            return String(localized: "Failed to access credentials: \(detail)", comment: "VPN error: could not load the SSH credential; detail is the reason")
        case .sshConnectionFailed(let detail):
            return String(localized: "SSH connection failed: \(detail)", comment: "VPN error: SSH handshake failed; detail is the reason")
        case .netstackFailed(let detail):
            return String(localized: "Network stack failed: \(detail)", comment: "VPN error: gVisor netstack failure; detail is the reason")
        case .extensionNotInstalled:
            return String(localized: "VPN extension is not installed", comment: "VPN error: the Network Extension is missing")
        case .extensionStartFailed(let detail):
            return String(localized: "Failed to start VPN extension: \(detail)", comment: "VPN error: the Network Extension would not start; detail is the reason")
        case .biometricAuthRequired:
            return String(localized: "Biometric authentication required to access VPN key", comment: "VPN error: the credential is biometric-gated and unreadable in the background")
        case .vpnKeyStoreFailed(let detail):
            return String(localized: "Failed to store VPN key copy: \(detail)", comment: "VPN error: could not persist the key copy; detail is the reason")
        case .unsupportedTransport(let detail):
            return String(localized: "Unsupported VPN transport: \(detail)", comment: "VPN error: the requested transport is not supported; detail is the transport name")
        case .invalidControlURL:
            return String(localized: "The Tailscale coordination server needs an HTTPS URL.", comment: "Tailscale error: the custom coordination server setting isn't an https URL")
        }
    }

    var isCredentialRelated: Bool {
        switch self {
        case .credentialAccessFailed, .biometricAuthRequired, .vpnKeyStoreFailed:
            return true
        default:
            return false
        }
    }
}
