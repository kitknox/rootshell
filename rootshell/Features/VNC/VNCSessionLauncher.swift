//
//  VNCSessionLauncher.swift
//  rootshell
//
//  Maps a VNCConnectionConfig + runtime password into the package's
//  (credentials, configuration) pair, installing a transportProvider for
//  jump connections. Jump specs (profiles, keys, saved passwords) are
//  resolved on the main actor BEFORE the provider closure is built, so
//  the @Sendable closure captures only resolved Sendable values and can
//  run per connection attempt off the main actor.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
import rootshellVNC
import RFBTransport

enum VNCLaunchError: LocalizedError {
    case jumpProfileNotFound
    case jumpKeysUnresolved(String)

    var errorDescription: String? {
        switch self {
        case .jumpProfileNotFound:
            return String(localized: "The jump profile for this Screen Sharing connection no longer exists.")
        case .jumpKeysUnresolved(let names):
            return String(localized: "The jump connection's SSH key is not available on this device (\(names)).")
        }
    }
}

@MainActor
enum VNCSessionLauncher {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "VNCSessionLauncher"
    )

    /// Build the credentials + configuration for one VNC session. For a
    /// non-direct `effectiveJump`, installs a `transportProvider` that
    /// creates a fresh tunnel transport per connection attempt.
    static func prepare(
        config: VNCConnectionConfig,
        password: String,
        onHostKeyValidation: (@Sendable (HostKeyValidationRequest) async -> HostKeyValidationResult)?,
        onCertificateValidation: VNCConfiguration.CertificateValidationHandler?
    ) async throws -> (credentials: VNCCredentials, configuration: VNCConfiguration) {
        // Finish the initial policy before the package activates remote audio.
        AppAudioSession.ensureConfigured()
        let credentials = config.toCredentials(password: password)
        var configuration = config.toPackageConfiguration()
        configuration.certificateValidationHandler = onCertificateValidation

        // High Performance requires direct UDP reachability; effectiveJump
        // already forces .none there, but flag stale persisted combinations.
        if case .none = config.jump {} else if !config.supportsJump {
            assert(config.quality != .adaptive || config.effectiveJump == .none)
            logger.warning("Ignoring jump configuration for High Performance connection")
        }

        let providers = try await RemoteScreenTransportFactory.providers(
            jump: config.effectiveJump,
            host: config.host,
            onHostKeyValidation: onHostKeyValidation)
        if let datagram = providers.datagram {
            configuration.datagramProvider = datagram
        }
        if let transport = providers.transport {
            configuration.transportProvider = transport
        }

        return (credentials, configuration)
    }
}
