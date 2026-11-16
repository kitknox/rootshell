//
//  YubiKeySlotManager.swift
//  rootshell
//
//  Handles PIV slot management operations (key deletion) on YubiKey
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os.log
import YubiKit

/// Handles PIV slot management operations on YubiKey
///
/// Operations like key deletion require management key authentication,
/// which is different from PIN-based authentication used for signing.
@MainActor
final class YubiKeySlotManager {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeySlotManager"
    )

    private let connectionManager: YubiKeyConnectionManager

    /// Default PIV management key (factory default) - Triple-DES (24 bytes)
    /// Used on older YubiKeys and YubiKey 5 series before firmware 5.4.2
    private static let defaultManagementKeyTripleDES = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ])

    /// Default PIV management key (factory default) - AES-192 (24 bytes)
    /// Used on YubiKey 5 series firmware 5.4.2 and later
    private static let defaultManagementKeyAES = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    ])

    init(connectionManager: YubiKeyConnectionManager? = nil) {
        self.connectionManager = connectionManager ?? YubiKeyConnectionManager.shared
    }

    // MARK: - Key Deletion

    /// Delete a key from a PIV slot
    ///
    /// This deletes both the certificate and the private key from the slot.
    /// PIV slots store key+certificate pairs, and discovery reads certificates,
    /// so we must delete the certificate for the slot to appear empty.
    ///
    /// - Parameters:
    ///   - slot: PIV slot to delete key from
    ///   - expectedSerial: Serial of the YubiKey the slot was listed from; any
    ///     other key is refused before anything is changed
    ///   - managementKey: Optional custom management key (uses default if nil)
    /// - Throws: YubiKeyError on failure
    func deleteKey(in slot: PIVSlot, expectedSerial: UInt32? = nil, managementKey: Data? = nil) async throws {
        Self.logger.info("Deleting key from slot \(slot.rawValue)")

        try await connectionManager.connect()

        // Over NFC the next tap can be a different YubiKey than the one listed.
        if let expectedSerial, case .connected(let serial, let method) = connectionManager.connectionState,
           serial != expectedSerial {
            #if os(iOS) && !os(visionOS)
            if method == .nfc {
                await connectionManager.closeNFCSession(withError: "Different YubiKey")
            }
            #endif
            throw YubiKeyError.keyDeletionFailed(
                "This is YubiKey \(serial), but the key was listed from YubiKey \(expectedSerial). Use that YubiKey to delete it."
            )
        }

        // Save connection method for cleanup
        let connectionMethod: YubiKeyConnectionMethod?
        if case .connected(_, let method) = connectionManager.connectionState {
            connectionMethod = method
        } else {
            connectionMethod = nil
        }

        let session = try await connectionManager.getPIVSession()

        do {
            // Authenticate with management key (required for key deletion)
            try await authenticateManagement(session: session, customKey: managementKey)

            let pivSlot = slot.toYubiKitSlot

            // Delete the certificate from the slot using new SDK
            // This is what discovery reads, so deleting it makes the slot appear empty
            do {
                try await session.deleteCertificate(in: pivSlot)
                Self.logger.info("Certificate deleted from slot \(slot.rawValue)")
            } catch {
                // SDK uses typed throws(PIVSessionError)
                throw YubiKeyError.keyDeletionFailed(String(describing: error))
            }

            // Also delete the key itself if supported (YubiKey 5.7+ with moveDelete feature)
            // The private key becomes unusable without the cert anyway
            if await session.supports(.moveDelete) {
                do {
                    try await session.deleteKey(in: pivSlot)
                    Self.logger.info("Private key deleted from slot \(slot.rawValue)")
                } catch {
                    // Log but don't fail - certificate deletion is the important part
                    Self.logger.warning("Key deletion returned error (may be expected): \(error)")
                }
            } else {
                Self.logger.info("Key deletion not supported on this YubiKey firmware - certificate deletion is sufficient")
            }

            Self.logger.info("Key deleted successfully from slot \(slot.rawValue)")

            // Handle NFC session closure
            #if os(iOS) && !os(visionOS)
            if connectionMethod == .nfc {
                await connectionManager.closeNFCSession(withMessage: "Key deleted")
                connectionManager.updateState(.disconnected)
            }
            #endif

        } catch {
            Self.logger.error("Key deletion failed: \(error.localizedDescription)")

            // Handle NFC session closure with error
            #if os(iOS) && !os(visionOS)
            if connectionMethod == .nfc {
                await connectionManager.closeNFCSession(withError: "Key deletion failed")
                connectionManager.updateState(.disconnected)
            }
            #endif
            throw error
        }
    }

    // MARK: - Management Key Authentication

    private func authenticateManagement(session: PIVSession, customKey: Data?) async throws {
        // New SDK auto-detects key type, so we just need to try with the key
        let keyToUse = customKey ?? Self.defaultManagementKeyAES

        do {
            // New SDK authenticate() auto-detects AES vs Triple-DES
            try await session.authenticate(with: keyToUse)
            Self.logger.info("Authenticated with management key")
        } catch {
            // If custom key failed, that's an error
            if customKey != nil {
                throw YubiKeyError.authenticationFailed("Management key authentication failed. The key may be incorrect.")
            }

            // Try Triple-DES default as fallback (older YubiKeys)
            do {
                try await session.authenticate(with: Self.defaultManagementKeyTripleDES)
                Self.logger.info("Authenticated with default Triple-DES management key")
            } catch {
                throw YubiKeyError.authenticationFailed(
                    "Management key authentication failed. Your YubiKey may have a non-default management key configured. " +
                    "Use YubiKey Manager to reset PIV or provide the correct management key."
                )
            }
        }
    }
}
