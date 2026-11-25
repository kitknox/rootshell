import Foundation
import Combine
import NIOSSH
import os.log

/// Errors surfaced while importing a host certificate authority.
enum HostCAImportError: LocalizedError {
    case invalidKey(String)
    case certificateNotAllowed
    case noPatterns
    case duplicate(existingName: String)

    var errorDescription: String? {
        switch self {
        case .invalidKey(let reason):
            return "Not a valid OpenSSH public key: \(reason)"
        case .certificateNotAllowed:
            return "This is a certificate, not a CA key. Paste the CA's public key (the key used to sign certificates), not a signed certificate."
        case .noPatterns:
            return "Enter at least one hostname pattern (e.g. *.example.com)."
        case .duplicate(let name):
            return "This CA key is already configured as \"\(name)\"."
        }
    }
}

/// Manages trusted OpenSSH host certificate authorities with sync-ready
/// file-based persistence. Parallels `KnownHostsManager`.
@MainActor
final class HostCAManager: ObservableObject {
    /// Shared singleton instance.
    static let shared = HostCAManager()

    /// File store for sync-ready per-record storage.
    private var store: SyncableFileStore<HostCertificateAuthority>

    /// Parsed CA public keys, cached by record ID to avoid re-parsing on every
    /// connection.
    private var parsedKeyCache: [UUID: NIOSSHPublicKey] = [:]

    private let logger = Logger(subsystem: "com.rootshell", category: "HostCA")

    /// Callback for CloudKit sync integration (mirrors KnownHostsManager).
    var onLocalChange: ((HostCertificateAuthority, SyncOperation) -> Void)? {
        didSet { store.onLocalChange = onLocalChange }
    }

    init() {
        self.store = SyncableFileStore<HostCertificateAuthority>(storeName: "host_cas")
        rebuildCache()
        logger.info("Loaded \(self.store.activeCount) host CAs")
    }

    // MARK: - Lookup

    /// All non-deleted CAs, sorted by name.
    var allCAs: [HostCertificateAuthority] {
        store.activeRecords.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var count: Int { store.activeCount }

    func getCA(id: UUID) -> HostCertificateAuthority? {
        let ca = store.record(for: id)
        return ca?.isDeleted == false ? ca : nil
    }

    /// Whether any configured CA applies to `host` (used to decide whether to
    /// advertise host-certificate algorithms for a connection).
    func hasCA(forHost host: String) -> Bool {
        store.activeRecords.contains { SSHHostPatternMatcher.matches(host: host, patterns: $0.hostPatterns) }
    }

    /// Parsed CA public keys whose patterns match `host`. These are the keys a
    /// presented host certificate's signature is checked against.
    func trustedCAKeys(forHost host: String) -> [NIOSSHPublicKey] {
        store.activeRecords.compactMap { ca in
            guard SSHHostPatternMatcher.matches(host: host, patterns: ca.hostPatterns) else { return nil }
            return parsedKey(for: ca)
        }
    }

    /// Canonical "<keytype> <base64>" strings of CAs whose patterns match
    /// `host`. Mirrored into the VPN profile snapshot so the extension (which
    /// cannot reach this store) can validate CA-signed host certificates.
    func trustedCAOpenSSHKeys(forHost host: String) -> [String] {
        store.activeRecords.compactMap { ca in
            SSHHostPatternMatcher.matches(host: host, patterns: ca.hostPatterns) ? ca.publicKeyOpenSSH : nil
        }
    }

    /// Parsed key for a CA, parsing + caching on demand.
    func parsedKey(for ca: HostCertificateAuthority) -> NIOSSHPublicKey? {
        if let cached = parsedKeyCache[ca.id] {
            return cached
        }
        SSHCustomAlgorithms.ensureRegistered()
        guard let key = try? NIOSSHPublicKey(openSSHPublicKey: ca.publicKeyOpenSSH) else {
            let name = ca.name
            logger.warning("Failed to parse stored CA key for \(name)")
            return nil
        }
        parsedKeyCache[ca.id] = key
        return key
    }

    // MARK: - Mutation

    /// Validate and add a CA. Throws `HostCAImportError` on bad input.
    @discardableResult
    func addCA(name: String, openSSHPublicKey: String, hostPatterns: [String]) throws -> HostCertificateAuthority {
        let trimmedKey = openSSHPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)

        SSHCustomAlgorithms.ensureRegistered()
        let key: NIOSSHPublicKey
        do {
            key = try NIOSSHPublicKey(openSSHPublicKey: trimmedKey)
        } catch {
            throw HostCAImportError.invalidKey(error.localizedDescription)
        }

        let keyType = SSHHostKeyFormatter.keyType(for: key)
        // A CA key must be a plain public key, never a certificate.
        guard !keyType.contains("-cert-v01") else {
            throw HostCAImportError.certificateNotAllowed
        }

        let patterns = Self.normalizePatterns(hostPatterns)
        guard !patterns.isEmpty else {
            throw HostCAImportError.noPatterns
        }

        let fingerprint = SSHHostKeyFormatter.fingerprint(for: key)
        if let existing = store.activeRecords.first(where: { $0.fingerprint == fingerprint }) {
            throw HostCAImportError.duplicate(existingName: existing.name)
        }

        // Canonical "<keytype> <base64>" form (drops any pasted comment).
        let canonical = String(openSSHPublicKey: key)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let ca = HostCertificateAuthority(
            name: trimmedName.isEmpty ? keyType : trimmedName,
            publicKeyOpenSSH: canonical,
            keyType: keyType,
            fingerprint: fingerprint,
            hostPatterns: patterns
        )

        objectWillChange.send()
        try store.save(ca)
        parsedKeyCache[ca.id] = key
        let savedName = ca.name
        logger.info("Added host CA: \(savedName)")
        refreshVPNProfileMirror()
        return ca
    }

    /// Adds the CA, or, when the same key (by fingerprint, as `addCA`
    /// dedupes) is already trusted, extends that record with `hostPatterns`.
    func addOrExtendCA(name: String, openSSHPublicKey: String, hostPatterns: [String]) throws {
        do {
            try addCA(name: name, openSSHPublicKey: openSSHPublicKey, hostPatterns: hostPatterns)
        } catch HostCAImportError.duplicate {
            SSHCustomAlgorithms.ensureRegistered()
            let key = try NIOSSHPublicKey(openSSHPublicKey: openSSHPublicKey.trimmingCharacters(in: .whitespacesAndNewlines))
            let fingerprint = SSHHostKeyFormatter.fingerprint(for: key)
            guard let existing = store.activeRecords.first(where: { $0.fingerprint == fingerprint }) else { return }
            let added = Self.normalizePatterns(hostPatterns).filter { !existing.hostPatterns.contains($0) }
            guard !added.isEmpty else { return }
            try update(id: existing.id, name: existing.name, hostPatterns: existing.hostPatterns + added)
        }
    }

    /// Re-mirror VPN profile snapshots so the trusted-CA lists stay current
    /// for extension/widget starts.
    private func refreshVPNProfileMirror() {
        ConnectionProfileManager.shared.refreshVPNSharedProfiles()
    }

    /// Update an existing CA's name and/or host patterns.
    func update(id: UUID, name: String, hostPatterns: [String]) throws {
        guard let existing = store.record(for: id) else { return }
        let patterns = Self.normalizePatterns(hostPatterns)
        guard !patterns.isEmpty else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = HostCertificateAuthority(
            id: existing.id,
            name: trimmedName.isEmpty ? existing.keyType : trimmedName,
            publicKeyOpenSSH: existing.publicKeyOpenSSH,
            keyType: existing.keyType,
            fingerprint: existing.fingerprint,
            hostPatterns: patterns,
            addedDate: existing.addedDate,
            modifiedAt: Date(),
            isDeleted: false
        )
        objectWillChange.send()
        try store.save(updated)
        refreshVPNProfileMirror()
    }

    func removeCA(id: UUID) {
        guard store.record(for: id) != nil else { return }
        objectWillChange.send()
        try? store.softDelete(id: id)
        parsedKeyCache.removeValue(forKey: id)
        logger.info("Removed host CA \(id.uuidString)")
        refreshVPNProfileMirror()
    }

    func removeAll() {
        objectWillChange.send()
        for ca in store.activeRecords {
            try? store.softDelete(id: ca.id)
        }
        parsedKeyCache.removeAll()
        logger.info("Removed all host CAs")
        refreshVPNProfileMirror()
    }

    func reload() {
        store.reload()
        rebuildCache()
    }

    // MARK: - Helpers

    private func rebuildCache() {
        // Runs at init and after sync merges — before any SSH connection has
        // registered the custom algorithms a stored CA key may need.
        SSHCustomAlgorithms.ensureRegistered()
        parsedKeyCache.removeAll()
        for ca in store.activeRecords {
            parsedKeyCache[ca.id] = try? NIOSSHPublicKey(openSSHPublicKey: ca.publicKeyOpenSSH)
        }
    }

    /// Split comma lists, trim, and drop empties.
    static func normalizePatterns(_ patterns: [String]) -> [String] {
        var result: [String] = []
        for entry in patterns {
            for part in entry.split(separator: ",", omittingEmptySubsequences: true) {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
            }
        }
        return result
    }
}
