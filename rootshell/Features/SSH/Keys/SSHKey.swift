import Foundation
import Citadel

// MARK: - Key Security Options

/// Controls where and how the key is stored in the keychain
nonisolated enum KeyStorageLevel: String, Codable, CaseIterable, Sendable {
    /// Key stays on this device only - not included in backups or sync
    case deviceOnly
    /// Key is included in encrypted device backups but not synced to iCloud
    case backupOnly
    /// Key syncs across devices via iCloud Keychain
    case iCloudSync

    var displayName: String {
        switch self {
        case .deviceOnly: return String(localized: "This Device Only", comment: "Key storage: device only")
        case .backupOnly: return String(localized: "Include in Backups", comment: "Key storage: include in backups")
        case .iCloudSync: return String(localized: "Sync with iCloud", comment: "Key storage: iCloud sync")
        }
    }

    var description: String {
        switch self {
        case .deviceOnly:
            return String(localized: "Key stays on this device only. Not included in backups or sync. Lost if device is reset.", comment: "Key storage description: device only")
        case .backupOnly:
            return String(localized: "Key is included in encrypted device backups but not synced to iCloud.", comment: "Key storage description: include in backups")
        case .iCloudSync:
            return String(localized: "Key syncs across your devices via iCloud Keychain.", comment: "Key storage description: iCloud sync")
        }
    }

    var iconName: String {
        switch self {
        case .deviceOnly: return "iphone"
        case .backupOnly: return "externaldrive"
        case .iCloudSync: return "icloud"
        }
    }
}

/// Controls when biometric/passcode authentication is required to use the key
nonisolated enum KeyAuthRequirement: String, Codable, CaseIterable, Sendable {
    static let iCloudAuthenticationAdvisory = String(
        localized: "For iCloud-synced keys, rootshell enforces this prompt before use; the synchronized Keychain item itself cannot use a device-bound access control.",
        comment: "Advisory explaining the app-level authentication gate for synchronized SSH and GPG keys"
    )

    /// No additional authentication required beyond device unlock
    case none
    /// Authenticate once per session (time-based expiry)
    case perSession
    /// Authenticate every time the key is used for signing
    case perUse

    var displayName: String {
        switch self {
        case .none: return String(localized: "None", comment: "Key auth requirement: none")
        case .perSession: return String(localized: "Once Per Session", comment: "Key auth requirement: per session")
        case .perUse: return String(localized: "Every Time", comment: "Key auth requirement: every use")
        }
    }

    var description: String {
        switch self {
        case .none:
            return String(localized: "No additional authentication required.", comment: "Key auth requirement description: none")
        case .perSession:
            return String(localized: "Authenticate once when you first use this key after opening the app.", comment: "Key auth requirement description: per session")
        case .perUse:
            return String(localized: "Authenticate every time this key is used for a connection.", comment: "Key auth requirement description: every use")
        }
    }

    var iconName: String {
        switch self {
        case .none: return "lock.open"
        case .perSession: return "timer"
        case .perUse: return "faceid"
        }
    }
}

// MARK: - SSH Key Model

/// Represents an SSH private key stored in the keychain
/// Metadata for an SSH key whose P-256 private key is generated inside the
/// Secure Enclave and can never be read by software (not even this app).
/// Only the public point is retained here so the SSH wire blob and
/// fingerprint can be rebuilt without touching the Keychain. The opaque
/// `dataRepresentation` reference (device-bound, useless elsewhere) lives in
/// the Keychain under the private-key service, like any other key id.
nonisolated struct SecureEnclaveKeyInfo: Codable, Hashable, Sendable {
    /// Uncompressed EC public point (65 bytes: 0x04 || x || y).
    let publicKeyX963: Data
    /// When the enclave key was generated.
    let createdDate: Date
}

/// An OpenSSH user certificate attached to a key (the contents of a `-cert.pub`
/// file, issued by a CA signing this key's public key). Public, non-secret data;
/// it lives in the key's metadata JSON so it follows the key's storageLevel sync
/// and is deleted with the key. One active certificate per key — replacing it is
/// how rotation works, matching OpenSSH's one `-cert.pub` per identity file.
nonisolated struct SSHUserCertificateInfo: Codable, Hashable, Sendable {
    /// Raw certificate wire blob (the base64-decoded portion of the cert line).
    /// Source of truth: used verbatim for auth offers, agent identities, and export.
    let certificateBlob: Data

    /// Certificate algorithm string, e.g. "ssh-ed25519-cert-v01@openssh.com".
    let certType: String

    /// CA-assigned key identity (free-form text, ssh-keygen -I).
    let keyID: String

    /// CA-assigned serial number (0 if the CA doesn't number certificates).
    let serial: UInt64

    /// Usernames this certificate is valid for. Empty = valid for any user.
    let validPrincipals: [String]

    /// Validity window start, seconds since epoch. 0 = no start bound.
    let validAfter: UInt64

    /// Validity window end, seconds since epoch. UInt64.max = never expires.
    let validBefore: UInt64

    /// CA public key type, e.g. "ssh-ed25519".
    let caKeyType: String

    /// CA public key fingerprint in `SSHHostKeyFormatter` display format
    /// ("SHA256:" + colon-separated hex), matching the Host CA UI.
    let caFingerprint: String

    /// Trailing comment from the imported cert line, if any.
    let comment: String?

    /// When the certificate was attached in this app.
    let addedDate: Date

    var isExpired: Bool {
        validBefore != .max && Date().timeIntervalSince1970 >= Double(validBefore)
    }

    var isNotYetValid: Bool {
        validAfter != 0 && Date().timeIntervalSince1970 < Double(validAfter)
    }

    /// Valid now but expiring within 30 days.
    var isExpiringSoon: Bool {
        guard validBefore != .max, !isExpired, !isNotYetValid else { return false }
        let thirtyDays: TimeInterval = 30 * 24 * 3600
        return Double(validBefore) - Date().timeIntervalSince1970 < thirtyDays
    }

    /// The authorized_keys-style one-line export: "<certType> <base64> <comment>".
    func exportLine(fallbackComment: String) -> String {
        let trailer = comment?.isEmpty == false ? comment! : fallbackComment
        return "\(certType) \(certificateBlob.base64EncodedString()) \(trailer)"
    }
}

/// Metadata for a key served by an external OpenSSH agent (1Password,
/// Secretive, ssh-agent) on this Mac. Only the public blob is tracked; every
/// signature is produced by the agent over its unix socket, so there is no
/// secret material anywhere in the app. Inherently device-local (the socket
/// only exists on this Mac) — these keys are forced to `.deviceOnly` storage.
nonisolated struct ExternalAgentKeyInfo: Codable, Hashable, Sendable {
    /// Registry entry (`ExternalSSHAgentRegistry`) this key came from. The
    /// live registry path wins over `socketPath` so re-pointing an agent
    /// entry fixes all of its keys at once.
    let agentID: UUID
    /// Socket path at import time; fallback when the registry entry is gone.
    let socketPath: String
    /// Agent-reported comment ("GitHub — 1Password").
    let comment: String
    /// Public key algorithm string ("ssh-ed25519", "ecdsa-sha2-nistp256",
    /// "ssh-rsa", ...) — the first SSH string of the public blob.
    let algorithm: String
    /// When the identity was imported from the agent.
    let addedDate: Date
}

nonisolated struct SSHKey: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier for the key (used as Keychain account identifier)
    let id: UUID

    /// User-provided name for the key (e.g., "Work Server", "GitHub")
    var name: String

    /// Type of SSH key algorithm
    var keyType: KeyType

    /// SHA256 fingerprint of the public key for identification
    let fingerprint: String

    /// Date when the key was imported
    let createdDate: Date

    /// Whether this key has an associated passphrase stored in keychain
    var hasPassphrase: Bool

    /// Controls where/how the key is stored (device-only, backup, or iCloud sync)
    var storageLevel: KeyStorageLevel

    /// Controls when biometric/passcode authentication is required
    var authRequirement: KeyAuthRequirement

    /// Date when security settings were last modified (nil if never changed)
    var securityModifiedDate: Date?

    /// Cached public key blob in SSH wire format (for agent forwarding matching without loading from Keychain)
    /// This avoids triggering biometric auth just to compare public keys
    var publicKeyBlob: Data?

    /// Cached GPG-agent-compatible keygrip for the public key material
    /// — used by GPG agent forwarding so a forwarded `KEYINFO` /
    /// `HAVEKEY` / `SIGKEY` can be matched against this SSH key
    /// without touching the Keychain. Uppercase hex with no
    /// separators (40 chars). Nil for legacy keys before this field
    /// existed and for hardware keys whose secret material isn't on
    /// device; the backfill loop populates it lazily for software keys.
    var gpgKeygripHex: String?

    /// GPG keygrip for this key's *encryption* role, exposed to
    /// forwarded GPG agents so the remote can drive `PKDECRYPT`
    /// against keys held on the iPad. For RSA and ECDSA P-256, this
    /// is the same value as ``gpgKeygripHex`` (the same key + same
    /// curve params serve both sign and encrypt). For Ed25519 it
    /// differs: the matching encryption keygrip is the cv25519
    /// keygrip computed from the X25519 public point derived from
    /// the Ed25519 seed, which has different curve params (Montgomery
    /// vs Edwards). Nil for legacy rows pre-dating PKDECRYPT support,
    /// hardware keys without on-device material, and key types we
    /// don't bridge.
    var gpgEncryptionKeygripHex: String?

    /// YubiKey-specific metadata (nil for software keys)
    var yubiKeyInfo: YubiKeyInfo?

    /// Apple FIDO2 credential info (for sk-ecdsa-sha2-nistp256 keys via AuthenticationServices)
    var appleFIDO2Info: AppleFIDO2CredentialInfo?

    /// Secure Enclave metadata (for keys whose P-256 private key is
    /// generated in and never leaves the Secure Enclave). All-platform —
    /// the Secure Enclave exists on iOS, iPadOS, macOS (Apple silicon / T2),
    /// and visionOS. Presence marks the key as hardware-protected with no
    /// software-accessible secret material.
    var secureEnclaveInfo: SecureEnclaveKeyInfo?

    /// OpenSSH user certificate attached to this key (nil if none).
    var userCertificate: SSHUserCertificateInfo?

    /// OpenPubkey (opkssh) identity metadata. Present when this key was
    /// created via "Sign In with OpenPubkey": the key is an ordinary P-256
    /// software key, but its certificate is the self-signed PK-token cert
    /// renewed from the OIDC provider rather than a CA-issued one.
    var openPubkeyInfo: OpenPubkeyInfo?

    /// Smallstep (step-ca) identity metadata. Present when this key was
    /// created via "Sign In with Smallstep": an ordinary software key whose
    /// certificate is short-lived and re-issued by the CA.
    var stepCAInfo: StepCAInfo?

    /// External-agent metadata (nil unless this key is served by a local
    /// OpenSSH agent on macOS). Decodable on every platform so a stray
    /// record can't crash decode; only the Catalyst Standalone build can
    /// actually sign with it.
    var externalAgentInfo: ExternalAgentKeyInfo?

    /// True when this key is an OpenPubkey identity.
    var isOpenPubkey: Bool { openPubkeyInfo != nil }

    /// True when this key's certificate is renewed by the app (OpenPubkey
    /// or step-ca) rather than imported by hand.
    var hasManagedCertificate: Bool { openPubkeyInfo != nil || stepCAInfo != nil }

    /// True when this key is served by an external OpenSSH agent.
    var isExternalAgentKey: Bool { externalAgentInfo != nil }

    /// True when this key is backed by a provider-managed platform passkey.
    var isPasskey: Bool {
        return appleFIDO2Info?.backing == .platformPasskey
    }

    /// Returns true if this key requires a hardware device for signing
    var isHardwareKey: Bool {
        return yubiKeyInfo != nil || appleFIDO2Info != nil || secureEnclaveInfo != nil || keyType.isHardwareKey
    }

    /// Returns the correct SSH key type string, considering YubiKey algorithm for PIV keys
    var effectiveSSHKeyTypeString: String {
        // Agent keys carry their real algorithm in the info struct; the
        // KeyType value is just the "SSH Agent" umbrella.
        if let externalAgentInfo = externalAgentInfo {
            return externalAgentInfo.algorithm
        }
        // For YubiKey PIV keys, use the actual algorithm's SSH key type string
        if let yubiKeyInfo = yubiKeyInfo {
            return yubiKeyInfo.algorithm.sshKeyTypeString
        }
        // Legacy hybrid keys retain their encoded name. In particular, the
        // authorized_keys text prefix must agree with the cached binary blob.
        if keyType == .mldsa44Ed25519, let blob = publicKeyBlob, blob.count >= 4 {
            let length = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            if length <= blob.count - 4,
               let name = String(data: blob.dropFirst(4).prefix(length), encoding: .utf8),
               name == MLDSA44Ed25519SSH.algorithmName || name == LegacyMLDSA44Ed25519SSH.algorithmName {
                return name
            }
        }
        // For all other key types, use the KeyType's SSH key type string
        return keyType.sshKeyTypeString
    }

    init(
        id: UUID = UUID(),
        name: String,
        keyType: KeyType,
        fingerprint: String,
        hasPassphrase: Bool = false,
        storageLevel: KeyStorageLevel = .backupOnly,
        authRequirement: KeyAuthRequirement = .none
    ) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.createdDate = Date()
        self.hasPassphrase = hasPassphrase
        self.storageLevel = storageLevel
        self.authRequirement = authRequirement
        self.securityModifiedDate = nil
        self.publicKeyBlob = nil
        self.yubiKeyInfo = nil
        self.appleFIDO2Info = nil
        self.secureEnclaveInfo = nil
        self.userCertificate = nil
        self.openPubkeyInfo = nil
        self.stepCAInfo = nil
        self.externalAgentInfo = nil
    }

    // MARK: - Codable (backward compatible)

    enum CodingKeys: String, CodingKey {
        case id, name, keyType, fingerprint, createdDate, hasPassphrase
        case storageLevel, authRequirement, securityModifiedDate, publicKeyBlob
        case gpgKeygripHex, gpgEncryptionKeygripHex
        case yubiKeyInfo, appleFIDO2Info, secureEnclaveInfo
        case userCertificate
        case openPubkeyInfo
        case stepCAInfo
        case externalAgentInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyType = try container.decode(KeyType.self, forKey: .keyType)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        hasPassphrase = try container.decode(Bool.self, forKey: .hasPassphrase)

        // New fields with backward-compatible defaults
        storageLevel = try container.decodeIfPresent(KeyStorageLevel.self, forKey: .storageLevel) ?? .backupOnly
        authRequirement = try container.decodeIfPresent(KeyAuthRequirement.self, forKey: .authRequirement) ?? .none
        securityModifiedDate = try container.decodeIfPresent(Date.self, forKey: .securityModifiedDate)
        publicKeyBlob = try container.decodeIfPresent(Data.self, forKey: .publicKeyBlob)
        gpgKeygripHex = try container.decodeIfPresent(String.self, forKey: .gpgKeygripHex)
        gpgEncryptionKeygripHex = try container.decodeIfPresent(String.self, forKey: .gpgEncryptionKeygripHex)
        yubiKeyInfo = try container.decodeIfPresent(YubiKeyInfo.self, forKey: .yubiKeyInfo)
        appleFIDO2Info = try container.decodeIfPresent(AppleFIDO2CredentialInfo.self, forKey: .appleFIDO2Info)
        secureEnclaveInfo = try container.decodeIfPresent(SecureEnclaveKeyInfo.self, forKey: .secureEnclaveInfo)
        userCertificate = try container.decodeIfPresent(SSHUserCertificateInfo.self, forKey: .userCertificate)
        openPubkeyInfo = try container.decodeIfPresent(OpenPubkeyInfo.self, forKey: .openPubkeyInfo)
        stepCAInfo = try container.decodeIfPresent(StepCAInfo.self, forKey: .stepCAInfo)
        externalAgentInfo = try container.decodeIfPresent(ExternalAgentKeyInfo.self, forKey: .externalAgentInfo)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(keyType, forKey: .keyType)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encode(hasPassphrase, forKey: .hasPassphrase)
        try container.encode(storageLevel, forKey: .storageLevel)
        try container.encode(authRequirement, forKey: .authRequirement)
        try container.encodeIfPresent(securityModifiedDate, forKey: .securityModifiedDate)
        try container.encodeIfPresent(publicKeyBlob, forKey: .publicKeyBlob)
        try container.encodeIfPresent(gpgKeygripHex, forKey: .gpgKeygripHex)
        try container.encodeIfPresent(gpgEncryptionKeygripHex, forKey: .gpgEncryptionKeygripHex)
        try container.encodeIfPresent(yubiKeyInfo, forKey: .yubiKeyInfo)
        try container.encodeIfPresent(appleFIDO2Info, forKey: .appleFIDO2Info)
        try container.encodeIfPresent(secureEnclaveInfo, forKey: .secureEnclaveInfo)
        try container.encodeIfPresent(userCertificate, forKey: .userCertificate)
        try container.encodeIfPresent(openPubkeyInfo, forKey: .openPubkeyInfo)
        try container.encodeIfPresent(stepCAInfo, forKey: .stepCAInfo)
        try container.encodeIfPresent(externalAgentInfo, forKey: .externalAgentInfo)
    }

    /// Supported SSH key types
    nonisolated enum KeyType: String, Codable, CaseIterable, Sendable {
        case rsa = "RSA"
        case ed25519 = "Ed25519"
        case ecdsaP256 = "ECDSA P-256"
        case ecdsaP384 = "ECDSA P-384"
        case ecdsaP521 = "ECDSA P-521"

        // YubiKey hardware key types
        case yubiKeyPIV = "YubiKey PIV"
        case yubiKeyFIDO2 = "YubiKey FIDO2"

        // Apple FIDO2 (via AuthenticationServices - cross-platform USB-C/NFC/Lightning)
        case appleFIDO2 = "FIDO2 Security Key"

        // Apple platform passkey (AuthenticationServices; any passkey provider)
        case applePasskey = "Passkey"

        // Secure Enclave (P-256, hardware-protected; private key never leaves the device)
        case secureEnclaveP256 = "Secure Enclave P-256"

        // External OpenSSH agent (1Password, Secretive, ssh-agent) on macOS.
        // The umbrella type for any algorithm; the real algorithm string
        // lives in ExternalAgentKeyInfo.algorithm.
        case externalAgent = "SSH Agent"

        // Post-quantum key types. Raw values are persisted in key
        // metadata — never change them. mldsa44Ed25519 is the OpenSSH 10.4+
        // composite; the pure ML-DSA types interop with OQS-style servers.
        case mldsa44Ed25519 = "ML-DSA-44 + Ed25519"
        case mldsa44 = "ML-DSA-44"
        case mldsa65 = "ML-DSA-65"
        case mldsa87 = "ML-DSA-87"

        /// Display name for UI
        var displayName: String {
            rawValue
        }

        /// Short identifier for compact display
        var shortName: String {
            switch self {
            case .rsa: return "RSA"
            case .ed25519: return "ED25519"
            case .ecdsaP256: return "P256"
            case .ecdsaP384: return "P384"
            case .ecdsaP521: return "P521"
            case .yubiKeyPIV: return "PIV"
            case .yubiKeyFIDO2: return "FIDO2"
            case .appleFIDO2: return "FIDO2"
            case .applePasskey: return "PASSKEY"
            case .secureEnclaveP256: return "SE P256"
            case .externalAgent: return "AGENT"
            case .mldsa44Ed25519: return "MLDSA44"
            case .mldsa44: return "MLDSA44"
            case .mldsa65: return "MLDSA65"
            case .mldsa87: return "MLDSA87"
            }
        }

        /// Color for key type badges in UI
        var badgeColor: String {
            switch self {
            case .rsa: return "red"
            case .ed25519: return "blue"
            case .ecdsaP256: return "green"
            case .ecdsaP384: return "orange"
            case .ecdsaP521: return "purple"
            case .yubiKeyPIV: return "yellow"
            case .yubiKeyFIDO2: return "cyan"
            case .appleFIDO2: return "teal"
            case .applePasskey: return "blue"
            case .secureEnclaveP256: return "indigo"
            case .externalAgent: return "mint"
            case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87: return "pink"
            }
        }

        /// SSH key type string used in public key format (e.g., "ssh-ed25519")
        var sshKeyTypeString: String {
            switch self {
            case .rsa: return "ssh-rsa"
            case .ed25519: return "ssh-ed25519"
            case .ecdsaP256: return "ecdsa-sha2-nistp256"
            case .ecdsaP384: return "ecdsa-sha2-nistp384"
            case .ecdsaP521: return "ecdsa-sha2-nistp521"
            case .yubiKeyPIV: return "ssh-rsa"  // PIV uses standard algorithms
            case .yubiKeyFIDO2: return "sk-ssh-ed25519@openssh.com"  // FIDO2 uses -SK suffix
            case .appleFIDO2: return "sk-ecdsa-sha2-nistp256@openssh.com"  // Apple FIDO2 is ECDSA P-256 only
            case .applePasskey: return "sk-ecdsa-sha2-nistp256@openssh.com"
            case .secureEnclaveP256: return "ecdsa-sha2-nistp256"  // Standard ECDSA P-256; key lives in the Secure Enclave
            case .externalAgent: return "ssh-ed25519"  // Placeholder; agent keys resolve via effectiveSSHKeyTypeString
            case .mldsa44Ed25519: return MLDSA44Ed25519SSH.algorithmName
            case .mldsa44: return "ssh-mldsa44"
            case .mldsa65: return "ssh-mldsa65"
            case .mldsa87: return "ssh-mldsa87"
            }
        }

        /// Whether this is a hardware security key type
        var isHardwareKey: Bool {
            switch self {
            case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
                return true
            case .externalAgent:
                // Not hardware, but shares the property that matters most
                // downstream: the secret is never software-accessible here.
                return true
            default:
                return false
            }
        }

        /// Whether this key type requires physical presence to sign
        var requiresPhysicalPresence: Bool {
            switch self {
            case .yubiKeyFIDO2, .appleFIDO2, .applePasskey:
                return true  // FIDO2 always requires touch
            default:
                return false  // Secure Enclave presence is governed by the per-key authRequirement, not the type
            }
        }

        /// Whether the private key material is accessible to software. Drives
        /// the "software vs hardware-protected" distinction in the key UI.
        /// Software keys (RSA/Ed25519/ECDSA) load their secret into app
        /// memory to sign; hardware-protected keys (Secure Enclave, YubiKey,
        /// FIDO2) never expose the secret to software.
        var hasSoftwareAccess: Bool {
            switch self {
            case .rsa, .ed25519, .ecdsaP256, .ecdsaP384, .ecdsaP521,
                 .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
                return true
            case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256, .externalAgent:
                return false
            }
        }
    }

    /// Formatted fingerprint for display (e.g., "SHA256:abc123...")
    var formattedFingerprint: String {
        "SHA256:\(fingerprint.prefix(16))..."
    }

    /// Full fingerprint with colons every 2 characters (e.g., "ab:cd:ef:12...")
    var colonFormattedFingerprint: String {
        let hex = fingerprint
        var result = ""
        for (index, char) in hex.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return result.uppercased()
    }
}
