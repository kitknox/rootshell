//
//  RemoteScreenTransportFactory.swift
//  rootshell
//
//  Builds the tunnel transport for a Screen Sharing or KVM jump. Jump specs
//  (profiles, keys, saved passwords) are resolved on the main actor BEFORE
//  the provider closure is built, so the @Sendable closure captures only
//  resolved Sendable values and can run per connection off the main actor.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import rootshellVNC
import RFBTransport

@MainActor
enum RemoteScreenTransportFactory {

    struct Providers {
        /// Nil for a plain direct connection.
        var transport: VNCTransportProvider?
        /// In-app Tailscale's datagram path for High Performance media.
        var datagram: VNCDatagramProvider?
    }

    static func providers(
        jump: VNCConnectionConfig.Jump,
        host: String,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws -> Providers {
        switch jump {
        case .none:
            #if !CHINA_BUILD
            // In-app Tailscale: the stream and High Performance media both ride the tailnet.
            if let ip = await TailnetDialer.route(host) {
                return Providers(
                    transport: { _, port in TailnetVNCTransport(host: ip, port: port) },
                    datagram: TailnetVNCTransport.datagramProvider)
            }
            #endif
            return Providers()

        case .sshProfile(let profileID):
            guard let profile = ConnectionProfileManager.shared.profile(for: profileID) else {
                throw VNCLaunchError.jumpProfileNotFound
            }
            let resolved = try await resolveJumpSSHConfig(profile.sshConfig, profileID: profileID)
            return Providers(transport: sshProvider(config: resolved, onHostKeyValidation: onHostKeyValidation))

        case .sshConfig(let sshConfig):
            let resolved = try await resolveJumpSSHConfig(sshConfig, profileID: nil)
            return Providers(transport: sshProvider(config: resolved, onHostKeyValidation: onHostKeyValidation))

        case .tsshProfile(let profileID):
            guard let profile = ConnectionProfileManager.shared.profile(for: profileID) else {
                throw VNCLaunchError.jumpProfileNotFound
            }
            let resolved = try await resolveJumpSSHConfig(profile.sshConfig, profileID: profileID)
            let transportMode = profile.trzszTransportMode
            let udpPortMin = profile.trzszPortMin ?? TrzszConfig.preferredUDPPortMin
            let udpPortMax = profile.trzszPortMax ?? TrzszConfig.preferredUDPPortMax
            let mtu = profile.trzszMTU ?? 0
            let connectTimeoutSec = profile.trzszConnectTimeoutSec
            let serverPath = profile.trzszServerPath
            return Providers(transport: { host, port in
                TSSHTunnelVNCTransport(
                    sshConfig: resolved,
                    transportMode: transportMode,
                    udpPortMin: udpPortMin,
                    udpPortMax: udpPortMax,
                    mtu: mtu,
                    connectTimeoutSec: connectTimeoutSec,
                    serverPath: serverPath,
                    vncHost: host,
                    vncPort: port,
                    onHostKeyValidation: onHostKeyValidation
                )
            })
        }
    }

    // MARK: - Jump resolution

    /// Resolve a jump SSH config to a directly connectable one: key UUIDs
    /// via ConnectionKeyResolver (device overrides included), then saved
    /// passwords inlined from the Keychain. Mirrors connectToProfile's
    /// resolve-then-config sequence, minus the interactive fallbacks
    /// (unresolved keys throw instead of opening a resolution sheet).
    /// Also resolves the SSH profile a pre-disconnect command runs through.
    static func resolveJumpSSHConfig(
        _ config: SSHConfig,
        profileID: UUID?
    ) async throws -> SSHConfig {
        var working = config

        switch ConnectionKeyResolver.resolve(config: working, profileID: profileID) {
        case .resolved(let resolved):
            working = resolved
        case .unresolved(_, let unresolvedKeys):
            let ids = unresolvedKeys
                .map { String($0.originalKeyID.uuidString.prefix(8)) }
                .joined(separator: ", ")
            throw VNCLaunchError.jumpKeysUnresolved(ids)
        }

        // Password auth with no inline value: fall back to a stored
        // password when one exists (same as connectToProfile).
        if case .password(let pwd) = working.authMethod, pwd.isEmpty,
           SSHPasswordManager.shared.hasPassword(
               host: working.host, port: working.port, username: working.username
           ) {
            working.authMethod = .savedPassword
        }

        return try await working.resolvedConfig()
    }

    /// Provider closure for the SSH jump. Captures only Sendable resolved
    /// values; runs off the main actor once per connection attempt.
    private static func sshProvider(
        config: SSHConfig,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) -> VNCTransportProvider {
        { host, port in
            SSHTunnelVNCTransport(
                sshConfig: config,
                vncHost: host,
                vncPort: port,
                onHostKeyValidation: onHostKeyValidation
            )
        }
    }
}
