//
//  YubiKeyModels.swift
//  rootshell
//
//  Data models for YubiKey hardware security key support
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import YubiKit

// MARK: - FormFactor Display Names

extension FormFactor {
    /// User-friendly display name for the YubiKey form factor
    var displayName: String {
        switch self {
        case .unknown: return "YubiKey"
        case .usbAKeychain: return "YubiKey 5 USB-A"
        case .usbANano: return "YubiKey 5 Nano"
        case .usbCKeychain: return "YubiKey 5C"
        case .usbCNano: return "YubiKey 5C Nano"
        case .usbCLightning: return "YubiKey 5Ci"
        case .usbABio: return "YubiKey Bio USB-A"
        case .usbCBio: return "YubiKey Bio USB-C"
        @unknown default: return "YubiKey"
        }
    }
}

// MARK: - PIV Slot

/// PIV (Personal Identity Verification) slots on a YubiKey
/// Each slot serves a specific purpose in the PIV specification
nonisolated enum PIVSlot: String, Codable, CaseIterable, Sendable {
    /// Authentication slot (9a) - Primary slot for SSH authentication
    case authentication = "9a"
    /// Digital Signature slot (9c) - For document signing, always requires PIN
    case signature = "9c"
    /// Key Management slot (9d) - For encryption/decryption operations
    case keyManagement = "9d"
    /// Card Authentication slot (9e) - For physical access, may not require PIN
    case cardAuthentication = "9e"

    var displayName: String {
        switch self {
        case .authentication: return String(localized: "Authentication (9a)", comment: "PIV slot: authentication")
        case .signature: return String(localized: "Digital Signature (9c)", comment: "PIV slot: digital signature")
        case .keyManagement: return String(localized: "Key Management (9d)", comment: "PIV slot: key management")
        case .cardAuthentication: return String(localized: "Card Auth (9e)", comment: "PIV slot: card authentication")
        }
    }

    var shortName: String {
        switch self {
        case .authentication: return "9a"
        case .signature: return "9c"
        case .keyManagement: return "9d"
        case .cardAuthentication: return "9e"
        }
    }

    /// Whether this slot typically requires PIN entry for signing
    /// Default PIV policy requires PIN for 9a, 9c, and 9d slots
    var requiresPIN: Bool {
        switch self {
        case .authentication, .signature, .keyManagement:
            return true  // Standard PIV policy requires PIN for these slots
        case .cardAuthentication:
            return false  // Card Auth (9e) typically doesn't require PIN
        }
    }

    /// Convert to YubiKit PIV.Slot
    var toYubiKitSlot: PIV.Slot {
        switch self {
        case .authentication: return .authentication
        case .signature: return .signature
        case .keyManagement: return .keyManagement
        case .cardAuthentication: return .cardAuth
        }
    }

    /// Convert from YubiKit PIV.Slot
    static func from(_ slot: PIV.Slot) -> PIVSlot? {
        switch slot {
        case .authentication: return .authentication
        case .signature: return .signature
        case .keyManagement: return .keyManagement
        case .cardAuth: return .cardAuthentication
        default: return nil  // Retired slots not supported
        }
    }
}

// MARK: - YubiKey Algorithm

/// Cryptographic algorithms supported by YubiKey for SSH
nonisolated enum YubiKeyAlgorithm: String, Codable, CaseIterable, Sendable {
    case rsa2048 = "RSA-2048"
    case rsa4096 = "RSA-4096"
    case ecdsaP256 = "ECDSA-P256"
    case ecdsaP384 = "ECDSA-P384"
    case ed25519 = "Ed25519"
    // Pure ML-DSA (FIPS 204) in PIV; YubiKey firmware 6.0+.
    case mldsa44 = "ML-DSA-44"
    case mldsa65 = "ML-DSA-65"
    case mldsa87 = "ML-DSA-87"

    var displayName: String {
        rawValue
    }

    /// SSH key type string used in public key format
    var sshKeyTypeString: String {
        switch self {
        case .rsa2048, .rsa4096:
            return "ssh-rsa"
        case .ecdsaP256:
            return "ecdsa-sha2-nistp256"
        case .ecdsaP384:
            return "ecdsa-sha2-nistp384"
        case .ed25519:
            return "ssh-ed25519"
        case .mldsa44:
            return "ssh-mldsa44"
        case .mldsa65:
            return "ssh-mldsa65"
        case .mldsa87:
            return "ssh-mldsa87"
        }
    }

    var mldsaParameterSet: YubiKit.MLDSA.ParameterSet? {
        switch self {
        case .mldsa44: return .mlDSA44
        case .mldsa65: return .mlDSA65
        case .mldsa87: return .mlDSA87
        case .rsa2048, .rsa4096, .ecdsaP256, .ecdsaP384, .ed25519: return nil
        }
    }

    var isPostQuantum: Bool { mldsaParameterSet != nil }

    /// Convert to YubiKit PIV.KeyType
    var toYubiKitKeyType: PIV.KeyType {
        switch self {
        case .rsa2048: return .rsa(.bits2048)
        case .rsa4096: return .rsa(.bits4096)
        case .ecdsaP256: return .ec(.secp256r1)
        case .ecdsaP384: return .ec(.secp384r1)
        case .ed25519: return .ed25519
        case .mldsa44: return .mlDSA(.mlDSA44)
        case .mldsa65: return .mlDSA(.mlDSA65)
        case .mldsa87: return .mlDSA(.mlDSA87)
        }
    }

    /// Convert from YubiKit PIV.KeyType
    static func from(_ keyType: PIV.KeyType) -> YubiKeyAlgorithm? {
        switch keyType {
        case .rsa(.bits2048): return .rsa2048
        case .rsa(.bits4096): return .rsa4096
        case .ec(.secp256r1): return .ecdsaP256
        case .ec(.secp384r1): return .ecdsaP384
        case .ed25519: return .ed25519
        case .mlDSA(.mlDSA44): return .mldsa44
        case .mlDSA(.mlDSA65): return .mldsa65
        case .mlDSA(.mlDSA87): return .mldsa87
        default: return nil
        }
    }
}

// MARK: - Connection Method

/// Physical connection method for YubiKey
nonisolated enum YubiKeyConnectionMethod: String, Codable, CaseIterable, Sendable {
    /// Lightning connector (YubiKey 5Ci)
    case lightning = "lightning"
    /// NFC (YubiKey 5 NFC, Security Key NFC)
    case nfc = "nfc"
    /// USB-C Smart Card (iPad with USB-C, iOS 16+)
    case usbc = "usb-c"

    var displayName: String {
        switch self {
        case .lightning: return "Lightning"
        case .nfc: return "NFC"
        case .usbc: return "USB-C"
        }
    }

    var iconName: String {
        switch self {
        case .lightning: return "cable.connector"
        case .nfc: return "wave.3.right"
        case .usbc: return "cable.connector.horizontal"
        }
    }
}

// MARK: - Device Snapshot

/// Identity of a YubiKey as last read, independent of whether it is still connected.
struct YubiKeyDeviceSnapshot: Equatable, Sendable {
    let serial: UInt32
    let firmwareVersion: String
    let formFactor: FormFactor
    let method: YubiKeyConnectionMethod

    var firmwareMajor: Int? {
        firmwareVersion.split(separator: ".").first.flatMap { Int($0) }
    }
}

// MARK: - Write Target

/// The YubiKey and slot an overwrite confirmation named. The write that follows
/// is bound to both, so a different key that answers the reconnect is refused.
struct YubiKeyWriteTarget: Equatable, Sendable {
    let serial: UInt32
    let slot: PIVSlot
}

// MARK: - YubiKey Info

/// Metadata about a PIV key stored on a YubiKey
/// This is stored alongside SSHKey metadata (no private key material is stored)
/// Note: FIDO2 keys are handled via Apple AuthenticationServices, not YubiKit
nonisolated struct YubiKeyInfo: Codable, Hashable, Sendable {
    /// Serial number of the YubiKey (for identification)
    let serialNumber: UInt32

    /// PIV slot where the key is stored
    let pivSlot: PIVSlot?

    /// Key algorithm
    let algorithm: YubiKeyAlgorithm

    /// Last connection method used successfully
    var lastConnectionMethod: YubiKeyConnectionMethod?

    /// Display name of the YubiKey device (e.g., "YubiKey 5 NFC")
    var deviceName: String?

    /// Human-readable description of where the key is stored
    var locationDescription: String {
        if let slot = pivSlot {
            return "PIV \(slot.displayName)"
        } else {
            return "YubiKey"
        }
    }

    /// Canonical hardware identifier for cross-device matching
    /// This allows the same physical YubiKey to be recognized across multiple iOS devices
    /// even when each device creates its own SSHKey record with a different UUID.
    /// Format: "piv:{serial}:{slot}" or "yubikey:{serial}"
    var hardwareIdentifier: String {
        if let slot = pivSlot {
            return "piv:\(serialNumber):\(slot.rawValue)"
        } else {
            return "yubikey:\(serialNumber)"
        }
    }
}

// MARK: - YubiKey Reference

/// Reference to a PIV key on a YubiKey for use in SSHPrivateKeyVariant
/// Contains only the information needed to locate and use the key - no key material
/// Note: FIDO2 keys are handled via Apple AuthenticationServices (AppleFIDO2Reference)
struct YubiKeyReference: Sendable, Hashable {
    /// SSHKey.id for looking up metadata
    let keyID: UUID

    /// YubiKey serial number for device matching
    let serialNumber: UInt32

    /// PIV slot where the key is stored
    let pivSlot: PIVSlot?

    /// Cached public key blob in SSH wire format
    let publicKeyBlob: Data

    /// Algorithm for signature formatting
    let algorithm: YubiKeyAlgorithm
}

// MARK: - Connection State

/// Connection state for YubiKey interactions
enum YubiKeyConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(method: YubiKeyConnectionMethod)
    /// Blocking on a wired (USB-C / Lightning) key to be inserted. Distinct
    /// from `.connecting` so the UI can show an indefinite "Insert your YubiKey"
    /// prompt instead of a generic spinner.
    case waitingForDevice(transport: YubiKeyConnectionMethod)
    case connected(serial: UInt32, method: YubiKeyConnectionMethod)
    case authenticating  // PIN entry in progress
    case signing         // Signing operation in progress
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .waitingForDevice, .authenticating, .signing:
            return true
        default:
            return false
        }
    }

    /// The transport we're actively trying to connect on, if any. True for both
    /// the brief `.connecting` window and the indefinite `.waitingForDevice`
    /// wait, so callers can treat "establishing a connection" uniformly.
    var connectingTransport: YubiKeyConnectionMethod? {
        switch self {
        case .connecting(let method): return method
        case .waitingForDevice(let transport): return transport
        default: return nil
        }
    }
}

// MARK: - PIN Request

/// Model for PIN entry requests shown to the user
struct YubiKeyPINRequest: Identifiable, Equatable, Sendable {
    /// Names this request to the prompt that shows it; a completion must quote it.
    let id: UUID
    let keyName: String
    let attemptsRemaining: Int?
    let completion: @Sendable (String?) -> Void  // nil = cancelled

    // Sendable conformance requires nonisolated init
    nonisolated init(
        id: UUID = UUID(),
        keyName: String,
        attemptsRemaining: Int?,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        self.id = id
        self.keyName = keyName
        self.attemptsRemaining = attemptsRemaining
        self.completion = completion
    }

    // Equatable conformance - compare by ID only (closure can't be compared)
    static func == (lhs: YubiKeyPINRequest, rhs: YubiKeyPINRequest) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Discovered Key

/// A PIV key discovered on a YubiKey during enumeration
/// Note: FIDO2 keys are handled via Apple AuthenticationServices
struct DiscoveredYubiKeyKey: Identifiable, Sendable {
    let id = UUID()

    /// Serial number of the YubiKey this key was discovered on
    let yubiKeySerial: UInt32

    /// PIV slot where the key is stored
    let slot: PIVSlot?

    /// Key algorithm
    let algorithm: YubiKeyAlgorithm

    /// Public key in SSH wire format
    let publicKeyData: Data

    /// SHA256 fingerprint (hex string without colons)
    let fingerprint: String

    /// Whether the key requires PIN for signing
    let requiresPIN: Bool

    /// Suggested name for import
    var suggestedName: String {
        if let slot = slot {
            return "YubiKey \(slot.displayName)"
        } else {
            return "YubiKey"
        }
    }
}
