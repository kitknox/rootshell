//
//  YubiKeyError.swift
//  rootshell
//
//  Error types for YubiKey operations
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import YubiKit

/// Errors that can occur during YubiKey operations
enum YubiKeyError: LocalizedError, Sendable {
    /// YubiKey is not connected
    case notConnected

    /// Failed to establish connection to YubiKey
    case connectionFailed(String? = nil)

    /// Connection was lost during operation
    case connectionLost

    /// PIN is required to access the key
    case pinRequired

    /// Entered PIN is incorrect
    case pinIncorrect(attemptsRemaining: Int)

    /// PIN has been blocked due to too many incorrect attempts
    case pinBlocked

    /// No key found in the specified PIV slot
    case keyNotFound(slot: PIVSlot?)

    /// Signing operation failed
    case signingFailed(String)

    /// Operation was cancelled by the user
    case userCancelled

    /// Touch is required to complete the operation
    case touchRequired

    /// Operation timed out waiting for YubiKey
    case timeout

    /// Timed out waiting for a YubiKey to be inserted on a wired transport
    case noDeviceDetected(transport: YubiKeyConnectionMethod)

    /// NFC is not available on this device
    case nfcNotAvailable

    /// NFC session was invalidated
    case nfcSessionInvalidated(String)

    /// Failed to read certificate from PIV slot
    case certificateReadFailed(String)

    /// Failed to convert key to SSH format
    case keyConversionFailed(String)

    /// YubiKey firmware doesn't support required feature
    case unsupportedFeature(String)

    /// Generic YubiKit error wrapper
    case yubiKitError(String)

    /// Key generation failed
    case keyGenerationFailed(String)

    /// Authentication with management key failed
    case authenticationFailed(String)

    /// PIN change operation failed
    case pinChangeFailed(String)

    /// Key deletion operation failed
    case keyDeletionFailed(String)

    /// New PIN confirmation doesn't match
    case pinMismatch

    /// Key type cannot be imported to YubiKey PIV
    case unsupportedKeyTypeForImport(String)

    /// RSA key is missing CRT parameters required for YubiKey import
    case missingCRTParameters

    /// Key is already stored on hardware and cannot be imported again
    case keyAlreadyOnHardware

    /// Import operation failed
    case importFailed(String)

    /// Slot already contains a key (for overwrite confirmation)
    case slotOccupied(PIVSlot)

    /// The connected YubiKey is not the one the action was confirmed or stored for
    case wrongDevice(expected: UInt32, connected: UInt32)

    /// The YubiKey or the stored key has no serial number to confirm its identity with
    case unverifiedDevice

    /// Another operation is using the YubiKey
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "YubiKey is not connected"
        case .connectionFailed(let detail):
            if let detail = detail {
                return "Failed to connect to YubiKey: \(detail)"
            }
            return "Failed to connect to YubiKey"
        case .connectionLost:
            return "Connection to YubiKey was lost"
        case .pinRequired:
            return "PIN is required to access this key"
        case .pinIncorrect(let attempts):
            if attempts == 1 {
                return "Incorrect PIN. 1 attempt remaining before lockout."
            }
            return "Incorrect PIN. \(attempts) attempts remaining."
        case .pinBlocked:
            return "YubiKey PIN is blocked. Use PUK to reset or factory reset the device."
        case .keyNotFound(let slot):
            if let slot = slot {
                return "No key found in \(slot.displayName)"
            }
            return "No key found on YubiKey"
        case .signingFailed(let reason):
            return "Signing failed: \(reason)"
        case .userCancelled:
            return "Operation cancelled"
        case .touchRequired:
            return "Touch your YubiKey to confirm"
        case .timeout:
            return "Operation timed out waiting for YubiKey"
        case .noDeviceDetected(let transport):
            return "No \(transport.displayName) YubiKey detected. Insert a key and try again."
        case .nfcNotAvailable:
            return "NFC is not available on this device"
        case .nfcSessionInvalidated(let reason):
            return "NFC session ended: \(reason)"
        case .certificateReadFailed(let reason):
            return "Failed to read certificate: \(reason)"
        case .keyConversionFailed(let reason):
            return "Failed to convert key: \(reason)"
        case .unsupportedFeature(let feature):
            return "YubiKey doesn't support: \(feature)"
        case .yubiKitError(let message):
            return "YubiKey error: \(message)"
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .pinChangeFailed(let reason):
            return "PIN change failed: \(reason)"
        case .keyDeletionFailed(let reason):
            return "Key deletion failed: \(reason)"
        case .pinMismatch:
            return "New PIN entries do not match"
        case .unsupportedKeyTypeForImport(let keyType):
            return "Cannot import \(keyType) keys to YubiKey PIV. Supported types: Ed25519, ECDSA P-256/P-384, RSA."
        case .missingCRTParameters:
            return "RSA key is missing CRT parameters required for YubiKey import."
        case .keyAlreadyOnHardware:
            return "This key is already stored on a hardware security key and cannot be imported again."
        case .importFailed(let reason):
            return "Key import failed: \(reason)"
        case .slotOccupied(let slot):
            return "The \(slot.displayName) slot already contains a key. Importing will overwrite it."
        case .wrongDevice(let expected, let connected):
            return "This is YubiKey \(connected), not YubiKey \(expected). Connect YubiKey \(expected) and try again."
        case .unverifiedDevice:
            return "The YubiKey's serial number isn't available, so this can't be confirmed as the right key."
        case .operationInProgress:
            return "Another YubiKey operation is in progress. Wait for it to finish, then try again."
        }
    }

    /// Whether this error indicates the user should retry with a PIN
    var requiresPINRetry: Bool {
        switch self {
        case .pinRequired, .pinIncorrect:
            return true
        default:
            return false
        }
    }

    /// Whether this error indicates the YubiKey needs to be reconnected
    var requiresReconnect: Bool {
        switch self {
        case .notConnected, .connectionFailed, .connectionLost, .nfcSessionInvalidated:
            return true
        default:
            return false
        }
    }

    /// Whether this error is recoverable by user action
    var isRecoverable: Bool {
        switch self {
        case .userCancelled, .pinBlocked, .unsupportedFeature:
            return false
        default:
            return true
        }
    }

    /// Whether this error indicates a security condition failure (e.g., PIN not verified)
    var isSecurityError: Bool {
        switch self {
        case .pinRequired, .pinIncorrect, .pinBlocked:
            return true
        case .signingFailed(let reason):
            // PIV status code 0x6982 = Security condition not satisfied
            return reason.contains("6982") || reason.lowercased().contains("security")
        default:
            return false
        }
    }

}

// MARK: - SDK Error Mapping

extension YubiKeyError {
    /// Create from PIVSessionError
    static func from(_ error: PIVSessionError) -> YubiKeyError {
        switch error {
        case .invalidPin(let retries, _):
            return retries > 0 ? .pinIncorrect(attemptsRemaining: retries) : .pinBlocked
        case .pinLocked:
            return .pinBlocked
        case .authenticationFailed:
            return .authenticationFailed("PIV authentication failed")
        case .featureNotSupported:
            return .unsupportedFeature("Feature not supported by this YubiKey")
        case .connectionError(let connectionError, _):
            return .from(connectionError)
        case .responseParseError(let message, _):
            return .yubiKitError(message)
        case .cryptoError(let message, _, _):
            return .signingFailed(message)
        case .illegalArgument(let message, _):
            return .yubiKitError(message)
        case .invalidKeyLength:
            return .keyGenerationFailed("Invalid key length")
        case .invalidDataSize:
            return .signingFailed("Invalid data size")
        case .failedResponse(let response, _):
            // Check for specific status codes
            let statusCode = response.responseStatus.status.rawValue
            switch statusCode {
            case 0x6982:
                // Security condition not satisfied - PIN verification needed
                return .pinRequired
            case 0x6983:
                // Authentication method blocked - PIN is blocked
                return .pinBlocked
            case 0x63C0...0x63CF:
                // Wrong PIN with retry count in low nibble
                let retries = Int(statusCode & 0x0F)
                return .pinIncorrect(attemptsRemaining: retries)
            default:
                return .signingFailed("PIV operation failed with status 0x\(String(format: "%04X", statusCode))")
            }
        default:
            return .yubiKitError(String(describing: error))
        }
    }

    /// Create from SmartCardConnectionError
    static func from(_ error: SmartCardConnectionError) -> YubiKeyError {
        switch error {
        case .connectionLost:
            return .connectionLost
        case .busy:
            return .connectionFailed("Another connection is in progress")
        case .unsupported:
            return .nfcNotAvailable
        case .cancelledByUser:
            return .userCancelled
        case .cancelled:
            return .userCancelled
        case .noDevicesFound:
            return .notConnected
        case .setupFailed(let message, _):
            return .connectionFailed(message)
        case .transmitFailed(let message, _):
            return .connectionFailed(message)
        case .malformedData(let message):
            return .yubiKitError(message ?? "Malformed data")
        case .pollingFailed(let message):
            return .connectionFailed(message)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the YubiKey is disconnected
    static let yubiKeyDidDisconnect = Notification.Name("yubiKeyDidDisconnect")
}
