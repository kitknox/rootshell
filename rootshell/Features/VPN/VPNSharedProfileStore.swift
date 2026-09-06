//
//  VPNSharedProfileStore.swift
//  rootshell
//
//  Shared non-secret VPN profile mirror stored in the app group for
//  extensions, widgets, and background App Intents.
//

import Foundation
import os.log

nonisolated enum VPNSharedTransportType: String, Codable, Sendable, Hashable {
    case ssh
    case tssh
}

nonisolated enum VPNSharedAuthMethod: String, Codable, Sendable, Hashable {
    case none
    case savedPassword
    case key
    case passwordRequired
}

nonisolated struct VPNSharedProfileAuth: Codable, Sendable, Hashable {
    var method: VPNSharedAuthMethod
    var keyID: UUID?

    var isBackgroundStartable: Bool {
        switch method {
        case .none, .savedPassword, .key:
            return true
        case .passwordRequired:
            return false
        }
    }
}

/// Host key pinned for the VPN path. Captured from KnownHostsManager in the
/// main app; the extension refuses to connect unless the server presents it.
nonisolated struct VPNPinnedHostKey: Codable, Sendable, Hashable {
    var keyType: String          // e.g. "ssh-ed25519"
    var publicKeyBase64: String  // base64 wire blob (KnownHost.publicKeyData)
    var fingerprint: String      // "SHA256:" + colon-hex (KnownHost.fingerprint)
}

nonisolated struct VPNSharedJumpHostSnapshot: Codable, Sendable, Hashable {
    var host: String
    var port: Int
    var username: String
    var auth: VPNSharedProfileAuth
    var hostKey: VPNPinnedHostKey?
    // Canonical "<keytype> <base64>" CA public keys (HostCAManager) whose
    // patterns match this host; a CA-signed host certificate validates
    // against these when no plain key is pinned.
    var trustedCAKeys: [String]?
}

nonisolated struct VPNSharedProfileSnapshot: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var modifiedAt: Date
    var name: String
    var host: String
    var port: Int
    var username: String
    var transportType: VPNSharedTransportType
    var auth: VPNSharedProfileAuth
    var jumpHost: VPNSharedJumpHostSnapshot?
    var trzszMode: String?
    var trzszUDPPortMin: Int?
    var trzszUDPPortMax: Int?
    var trzszMTU: Int?
    var trzszServerPath: String?
    var dnsServers: [String]
    var excludedRoutes: [String]
    // Reject QUIC (UDP 443) with ICMP so browsers fall back to HTTP/2.
    // Optional so profiles mirrored by older builds still decode.
    var blockQUIC: Bool?
    var isBackgroundStartable: Bool
    var hostKey: VPNPinnedHostKey?
    var trustedCAKeys: [String]?
}

private nonisolated struct VPNSharedProfileStorePayload: Codable, Sendable {
    var version: Int
    var lastUpdated: Date
    var profiles: [VPNSharedProfileSnapshot]
}

nonisolated enum VPNSharedProfileStore {
    private static let logger = Logger(subsystem: "com.rootshell", category: "VPNSharedProfileStore")

    static let currentVersion = 1
    static let fileName = "vpn_profiles.json"

    static let appGroupID = AppIdentifiers.defaultAppGroupID

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    static func write(_ profiles: [VPNSharedProfileSnapshot]) {
        guard let fileURL else {
            logger.error("App group container unavailable for VPN shared profile write")
            return
        }

        let payload = VPNSharedProfileStorePayload(
            version: currentVersion,
            lastUpdated: Date(),
            profiles: profiles.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to write VPN shared profiles: \(error.localizedDescription)")
        }
    }

    static func readAll() -> [VPNSharedProfileSnapshot] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(VPNSharedProfileStorePayload.self, from: data)
            return payload.profiles
        } catch {
            logger.error("Failed to read VPN shared profiles: \(error.localizedDescription)")
            return []
        }
    }

    static func profile(id: UUID) -> VPNSharedProfileSnapshot? {
        readAll().first(where: { $0.id == id })
    }
}
