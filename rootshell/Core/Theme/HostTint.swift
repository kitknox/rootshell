//
//  HostTint.swift
//  rootshell
//
//  Derives a per-destination background tint from the remote host key
//  fingerprint, so the same server always gets the same variant of the
//  active theme regardless of which profile or config reached it.
//

import CryptoKit
import Foundation
import UIKit

/// Host key fingerprints seen this run, keyed by the hostname/port the
/// validator was given. Falls back to known_hosts before a handshake completes.
@MainActor
final class HostFingerprintRegistry {
    static let shared = HostFingerprintRegistry()

    private var fingerprints: [String: String] = [:]
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    private init() {}

    private static func key(_ hostname: String, _ port: Int) -> String {
        "\(hostname.lowercased()):\(port)"
    }

    func record(hostname: String, port: Int, fingerprint: String) {
        let key = Self.key(hostname, port)
        guard fingerprints[key] != fingerprint else { return }
        fingerprints[key] = fingerprint
        for continuation in continuations.values { continuation.yield() }
    }

    func fingerprint(hostname: String, port: Int) -> String? {
        fingerprints[Self.key(hostname, port)]
            ?? KnownHostsManager.shared.getHost(hostname: hostname, port: port)?.fingerprint
    }

    /// The fingerprint a connection's background is tinted by, or nil when
    /// Tint by Host is off or the connection is not SSH.
    func tintFingerprint(for connection: ConnectionConfig) -> String? {
        guard SettingsStore.shared.get(Settings.Theme.hostTint),
              let ssh = connection.underlyingSSHConfig else { return nil }
        return fingerprint(hostname: ssh.host, port: ssh.port)
    }

    /// Yields whenever a host's recorded fingerprint changes.
    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations.removeValue(forKey: id) }
            }
        }
    }
}

nonisolated enum HostTint {
    /// Stable hue in [0, 1) for a fingerprint. Never use `Hasher`; it is seeded per launch.
    static func hue(for fingerprint: String) -> CGFloat {
        let digest = Array(SHA256.hash(data: Data(fingerprint.utf8)))
        return CGFloat(UInt16(digest[0]) << 8 | UInt16(digest[1])) / 65536
    }

    /// The theme background nudged toward the fingerprint's hue, keeping its lightness.
    static func tintedBackground(red: UInt8, green: UInt8, blue: UInt8, fingerprint: String) -> String {
        let base = [CGFloat(red), CGFloat(green), CGFloat(blue)].map { $0 / 255 }
        let luminance = 0.2126 * base[0] + 0.7152 * base[1] + 0.0722 * base[2]
        let isLight = luminance > 0.5
        let target = UIColor(
            hue: hue(for: fingerprint),
            saturation: isLight ? 0.45 : 0.7,
            brightness: isLight ? 0.9 : 0.6,
            alpha: 1)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let amount: CGFloat = isLight ? 0.14 : 0.12
        let mixed = zip(base, [tr, tg, tb]).map { a, b in
            min(max(Int(((a + (b - a) * amount) * 255).rounded()), 0), 255)
        }
        return String(format: "#%02x%02x%02x", mixed[0], mixed[1], mixed[2])
    }
}
