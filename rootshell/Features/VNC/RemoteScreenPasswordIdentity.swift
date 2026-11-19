//
//  RemoteScreenPasswordIdentity.swift
//  rootshell
//
//  Route-aware Keychain accounts for Screen Sharing and KVM device passwords.
//

import Foundation
import os

/// A remote screen endpoint whose saved password belongs to one route: the
/// same private address behind two jump hosts is two machines.
protocol RemoteScreenPasswordIdentity {
    /// Keychain account, including the jump route.
    var passwordKey: String { get }
    /// The account builds before the route was part of the key used.
    var legacyPasswordKey: String { get }
    /// The jump the connection actually takes.
    var routeJump: VNCConnectionConfig.Jump { get }
}

/// A route captured in one step: the key a password is saved under and the
/// jump profile the tunnel dials. Panes hold one per password or prompt.
struct RemoteScreenRoute {
    let passwordKey: String
    let jumpProfile: ConnectionProfile?
    /// A jump profile not on this device yet; no password belongs to it.
    let isUnresolved: Bool
}

/// A typed, unsaved password for one connection attempt. The pane uses it
/// only if its own route still has this key, and discards it otherwise.
struct RemoteScreenPasswordHandoff {
    let password: String
    let passwordKey: String
}

extension RemoteScreenPasswordIdentity {
    var currentRoute: RemoteScreenRoute {
        let profile = routeJump.currentProfile
        let usesProfile: Bool
        switch routeJump {
        case .sshProfile, .tsshProfile: usesProfile = true
        case .none, .sshConfig: usesProfile = false
        }
        return RemoteScreenRoute(
            passwordKey: passwordKey,
            jumpProfile: profile,
            isUnresolved: usesProfile && profile == nil)
    }
}

extension VNCConnectionConfig.Jump {
    /// The jump profile as it is now. Sessions capture it alongside the
    /// password so every tunnel they build dials the same hosts.
    var currentProfile: ConnectionProfile? {
        switch self {
        case .sshProfile(let id), .tsshProfile(let id):
            return ConnectionProfileManager.shared.profile(for: id)
        case .none, .sshConfig:
            return nil
        }
    }

    /// Hops as the transport dials them, so repointing a jump profile asks
    /// for the password again. The profile ID stays in too: two profiles
    /// with one `.local` name can fall back to different cached IPs.
    var passwordRouteIdentity: String {
        switch self {
        case .none:
            return "direct"
        case .sshProfile(let id), .tsshProfile(let id):
            guard let profile = currentProfile else {
                return "missing profile \(id.uuidString)"
            }
            return "profile \(id.uuidString) " + Self.hopsIdentity(profile.sshConfig)
        case .sshConfig(let config):
            return Self.hopsIdentity(config)
        }
    }

    private static func hopsIdentity(_ config: SSHConfig) -> String {
        let hops = config.jumpChain.map { "\($0.username)@\($0.host):\($0.port)" }
            + ["\(config.username)@\(config.host):\(config.port)"]
        return "ssh " + hops.joined(separator: " > ")
    }
}

extension VNCConnectionConfig: RemoteScreenPasswordIdentity {
    var legacyPasswordKey: String {
        "\(username ?? "")@\(host):\(port)"
    }

    /// High Performance ignores the jump, so it keys as direct.
    var routeJump: Jump { effectiveJump }

    var passwordKey: String {
        "\(legacyPasswordKey) via \(routeJump.passwordRouteIdentity)"
    }
}

extension KVMConnectionConfig: RemoteScreenPasswordIdentity {
    var legacyPasswordKey: String {
        "kvm:\(username)@\(host):\(port)"
    }

    var routeJump: Jump { jump }

    var passwordKey: String {
        "\(legacyPasswordKey) via \(routeJump.passwordRouteIdentity)"
    }
}

// MARK: - Route-Aware Storage

/// Old-format items carry no route, so they are never sent without the
/// user choosing them, and never deleted: older builds still read them.
extension VNCPasswordManager {
    enum SavedState: Equatable {
        case notSaved
        case saved
        /// Only an old-format item exists. Offer it; don't send it.
        case needsConfirmation
    }

    func savedState(for identity: some RemoteScreenPasswordIdentity) -> SavedState {
        if hasPassword(for: identity.passwordKey) { return .saved }
        guard hasPassword(for: identity.legacyPasswordKey),
              !hasPassword(for: Self.legacyDismissedKey(identity.passwordKey)) else { return .notSaved }
        return .needsConfirmation
    }

    func loadPassword(for identity: some RemoteScreenPasswordIdentity) throws -> String {
        try loadPassword(for: identity.passwordKey)
    }

    /// The user picked the old-format item. Rechecked here because the prompt
    /// can sit open while another pane saves or removes this route's password.
    /// `save` copies it to the route's key, like the prompt's toggle.
    func useLegacyPassword(for identity: some RemoteScreenPasswordIdentity, save: Bool) throws -> String {
        switch savedState(for: identity) {
        case .saved:
            return try loadPassword(for: identity)
        case .notSaved:
            throw PasswordError.notFound
        case .needsConfirmation:
            break
        }
        let password = try loadPassword(for: identity.legacyPasswordKey)
        if save {
            do {
                try savePassword(password, for: identity.passwordKey)
            } catch {
                Self.logger.error("Failed to adopt saved password: \(error.localizedDescription, privacy: .public)")
            }
        }
        return password
    }

    /// Refuses a route whose jump profile hasn't synced: its key changes once
    /// the profile arrives, so the password would never be found.
    func savePassword(_ password: String, for identity: some RemoteScreenPasswordIdentity) throws {
        guard !identity.currentRoute.isUnresolved else { throw PasswordError.jumpProfileMissing }
        try savePassword(password, for: identity.passwordKey)
    }

    /// Takes a captured route, so a screen removes the password whose status
    /// it showed even if the route moved since. A shared old-format item stays
    /// for other routes; a marker stops this one offering it again. Written
    /// even with no old item visible: one can still arrive through iCloud Keychain.
    func deletePassword(for route: RemoteScreenRoute) throws {
        try deletePassword(for: route.passwordKey)
        try savePassword("", for: Self.legacyDismissedKey(route.passwordKey))
    }

    private static func legacyDismissedKey(_ passwordKey: String) -> String {
        "\(passwordKey) legacy-dismissed"
    }
}
