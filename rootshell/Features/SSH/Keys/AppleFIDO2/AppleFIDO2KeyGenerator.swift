//
//  AppleFIDO2KeyGenerator.swift
//  rootshell
//
//  WebAuthn key generation via Apple AuthenticationServices.
//  Creates either external security-key credentials or platform passkeys.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import AuthenticationServices
import CryptoKit
import Foundation
import os.log

/// Generates FIDO2 credentials for SSH authentication using Apple AuthenticationServices
/// This enables cross-platform credential creation (iOS, iPadOS, Mac Catalyst)
@MainActor final class AppleFIDO2KeyGenerator: NSObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AppleFIDO2KeyGenerator")

    /// Current operation state for UI feedback (use Swift 6 patterns instead of Combine)
    private(set) var state: AppleFIDO2State = .idle

    /// Continuation for async/await bridge
    private var registrationContinuation: CheckedContinuation<AppleFIDO2CredentialInfo, Error>?

    /// User name being registered
    private var currentUserName: String = ""

    /// User handle being registered
    private var currentUserHandle: Data = Data()

    /// Credential store selected for the in-flight registration.
    private var currentBacking: AppleFIDO2CredentialBacking = .securityKey

    /// Presentation anchor for authorization UI
    private weak var presentationAnchor: ASPresentationAnchor?

    /// Retain the controller for the duration of the async operation.
    private var authorizationController: ASAuthorizationController?

    override init() { super.init() }

    /// Set the presentation anchor for the authorization UI
    /// - Parameter anchor: The window to present the authorization UI from
    func setPresentationAnchor(_ anchor: ASPresentationAnchor?) { self.presentationAnchor = anchor }

    /// Generate a new FIDO2 credential for SSH authentication
    ///
    /// This method:
    /// 1. Creates a registration request with ECDSA P-256 algorithm
    /// 2. Presents the system authorization UI
    /// 3. Extracts the credential ID and public key from the attestation
    /// 4. Returns credential info ready for storage
    ///
    /// - Parameters:
    ///   - userName: Display name for the credential (shown during authentication)
    ///   - userHandle: Unique identifier for the user (used as user.id)
    /// - Returns: The created credential info
    /// - Throws: AppleFIDO2Error if registration fails
    func generateKey(userName: String, backing: AppleFIDO2CredentialBacking = .securityKey, userHandle: Data? = nil) async throws -> AppleFIDO2CredentialInfo {
        Self.logger.info("Starting WebAuthn registration for user: \(userName), backing: \(backing.rawValue)")

        state = .waitingForSecurityKey(operation: String(localized: "Creating credential", comment: "WebAuthn registration progress"))

        // Store for use in delegate
        self.currentUserName = userName
        self.currentUserHandle = userHandle ?? generateUserHandle()
        self.currentBacking = backing

        // Create a random challenge (attestation doesn't need specific challenge for SSH)
        var challengeBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, challengeBytes.count, &challengeBytes) == errSecSuccess else {
            throw AppleFIDO2Error.registrationFailed(
                String(localized: "Could not generate a secure challenge.", comment: "Passkey/security-key registration error detail"))
        }
        let challenge = Data(challengeBytes)

        let authorizationRequest: ASAuthorizationRequest
        switch backing {
        case .securityKey:
            // visionOS ships no external security-key support, only platform passkeys.
            #if os(visionOS)
            state = .failed(AppleFIDO2Error.platformNotSupported.localizedDescription)
            throw AppleFIDO2Error.platformNotSupported
            #else
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: AppleFIDO2CredentialInfo.sshRpID)
            let request = provider.createCredentialRegistrationRequest(challenge: challenge, displayName: userName, name: userName, userID: currentUserHandle)
            request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
            request.residentKeyPreference = .preferred
            request.userVerificationPreference = .discouraged
            request.attestationPreference = .none
            authorizationRequest = request
            #endif

        case .platformPasskey:
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: AppleFIDO2CredentialInfo.sshRpID)
            let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: currentUserHandle)
            request.displayName = userName
            request.userVerificationPreference = .required
            request.attestationPreference = .none
            authorizationRequest = request
        }

        // Create and configure the authorization controller
        let authController = ASAuthorizationController(authorizationRequests: [authorizationRequest])
        authController.delegate = self
        authController.presentationContextProvider = self
        authorizationController = authController

        return try await withCheckedThrowingContinuation { continuation in
            self.registrationContinuation = continuation
            authController.performRequests()
        }
    }

    /// Generate a random user handle
    private func generateUserHandle() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AppleFIDO2KeyGenerator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            Self.logger.info("Registration completed successfully")

            guard let credential = authorization.credential as? any ASAuthorizationPublicKeyCredentialRegistration,
                credentialMatchesCurrentBacking(authorization.credential)
            else {
                Self.logger.error("Unexpected credential type")
                state = .failed(String(localized: "Unexpected credential type", comment: "WebAuthn registration status error"))
                finishRegistration(
                    with: .failure(
                        AppleFIDO2Error.invalidCredential(
                            String(
                                localized: "Credential provider returned the wrong registration type.",
                                comment: "Passkey/security-key registration error detail"))))
                return
            }

            // Extract credential ID
            let credentialID = credential.credentialID
            Self.logger.info("Got credential ID: \(credentialID.count) bytes")

            // Extract public key from attestation object
            guard let publicKeyPoint = extractPublicKeyFromAttestation(credential.rawAttestationObject) else {
                Self.logger.error("Failed to extract public key from attestation")
                state = .failed(String(localized: "Failed to extract public key", comment: "WebAuthn registration status error"))
                finishRegistration(
                    with: .failure(
                        AppleFIDO2Error.registrationFailed(
                            String(localized: "Could not extract an ES256 P-256 public key.", comment: "Passkey/security-key registration error detail"))))
                return
            }

            Self.logger.info("Extracted public key: \(publicKeyPoint.count) bytes")

            // Create credential info
            let credentialInfo = AppleFIDO2CredentialInfo(
                credentialID: credentialID, rpID: AppleFIDO2CredentialInfo.sshRpID, userHandle: currentUserHandle, userName: currentUserName,
                publicKeyPoint: publicKeyPoint, backing: currentBacking)

            state = .success
            finishRegistration(with: .success(credentialInfo))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            Self.logger.error("Registration failed: \(error.localizedDescription)")

            let appleFIDO2Error = mapAuthorizationError(error)
            state = .failed(appleFIDO2Error.localizedDescription)
            finishRegistration(with: .failure(appleFIDO2Error))
        }
    }

    private func credentialMatchesCurrentBacking(_ credential: any ASAuthorizationCredential) -> Bool {
        switch currentBacking {
        case .securityKey:
            #if os(visionOS)
            return false
            #else
            return credential is ASAuthorizationSecurityKeyPublicKeyCredentialRegistration
            #endif
        case .platformPasskey: return credential is ASAuthorizationPlatformPublicKeyCredentialRegistration
        }
    }

    private func finishRegistration(with result: Result<AppleFIDO2CredentialInfo, Error>) {
        let continuation = registrationContinuation
        registrationContinuation = nil
        authorizationController = nil
        continuation?.resume(with: result)
    }

    /// Extract public key from CBOR-encoded attestation object
    private func extractPublicKeyFromAttestation(_ attestationObject: Data?) -> Data? {
        guard let attestation = attestationObject else {
            Self.logger.error("No attestation object")
            return nil
        }

        // The attestation object is CBOR-encoded with structure:
        // { "fmt": string, "attStmt": map, "authData": bytes }
        // We need to parse authData to get the public key

        // Simple CBOR parsing for attestation object
        guard let authData = extractAuthDataFromCBOR(attestation) else {
            Self.logger.error("Failed to extract authData from attestation")
            return nil
        }

        // authData structure:
        // rpIdHash (32 bytes) || flags (1 byte) || signCount (4 bytes) || attestedCredentialData (variable)
        // attestedCredentialData structure:
        // aaguid (16 bytes) || credentialIdLength (2 bytes) || credentialId (variable) || credentialPublicKey (COSE)

        guard authData.count > 37 else {
            Self.logger.error("authData too short: \(authData.count) bytes")
            return nil
        }

        let flagIndex = 32
        let flags = authData[flagIndex]

        // Check AT (attested credential data present) flag
        guard flags & 0x40 != 0 else {
            Self.logger.error("No attested credential data in authData")
            return nil
        }

        // Skip rpIdHash (32) + flags (1) + signCount (4) = 37
        var offset = 37

        // Skip aaguid (16 bytes)
        offset += 16

        guard offset + 2 <= authData.count else {
            Self.logger.error("authData too short for credentialIdLength")
            return nil
        }

        // Credential ID length (big-endian uint16)
        let credIdLength = Int(authData[offset]) << 8 | Int(authData[offset + 1])
        offset += 2

        // Skip credential ID
        offset += credIdLength

        guard offset < authData.count else {
            Self.logger.error("No public key data in authData")
            return nil
        }

        // The remaining bytes are the COSE-encoded public key
        let coseKey = authData[offset...]

        // Parse COSE key to extract EC point
        return extractECPointFromCOSE(Data(coseKey))
    }

    /// Extract authData from CBOR-encoded attestation object
    /// Simple CBOR parser for WebAuthn attestation structure
    private func extractAuthDataFromCBOR(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0

        // Expect map at top level
        guard offset < bytes.count else { return nil }
        let firstByte = bytes[offset]

        // CBOR map (0xa0-0xbf for small maps, 0xbf for indefinite)
        guard (firstByte & 0xe0) == 0xa0 || firstByte == 0xbf else {
            Self.logger.error("Expected CBOR map, got: 0x\(String(format: "%02x", firstByte))")
            return nil
        }

        let mapSize: Int
        if firstByte == 0xbf {
            // Indefinite length - scan for "authData" key
            mapSize = -1
            offset += 1
        } else {
            mapSize = Int(firstByte & 0x1f)
            offset += 1
        }

        // Search for "authData" key
        var itemsProcessed = 0
        while offset < bytes.count {
            if mapSize >= 0 && itemsProcessed >= mapSize * 2 { break }

            // Break marker for indefinite map
            if bytes[offset] == 0xff { break }

            // Read key
            guard let (key, keyLen) = readCBORString(bytes: bytes, offset: offset) else {
                // Skip unknown key type
                guard let skipLen = skipCBORItem(bytes: bytes, offset: offset) else { return nil }
                offset += skipLen
                guard let skipLen2 = skipCBORItem(bytes: bytes, offset: offset) else { return nil }
                offset += skipLen2
                itemsProcessed += 2
                continue
            }
            offset += keyLen
            itemsProcessed += 1

            if key == "authData" {
                // Read byte string value
                guard let (authData, _) = readCBORByteString(bytes: bytes, offset: offset) else { return nil }
                return authData
            } else {
                // Skip value
                guard let skipLen = skipCBORItem(bytes: bytes, offset: offset) else { return nil }
                offset += skipLen
                itemsProcessed += 1
            }
        }

        return nil
    }

    /// Read a CBOR text string
    private func readCBORString(bytes: [UInt8], offset: Int) -> (String, Int)? {
        guard offset < bytes.count else { return nil }
        let firstByte = bytes[offset]

        // Text string (0x60-0x7f for small, 0x78-0x7b for larger)
        guard (firstByte & 0xe0) == 0x60 else { return nil }

        let (length, headerLen) = cborLength(firstByte: firstByte, bytes: bytes, offset: offset)
        guard let len = length else { return nil }

        let start = offset + headerLen
        guard start + len <= bytes.count else { return nil }

        let stringData = Data(bytes[start..<start + len])
        guard let string = String(data: stringData, encoding: .utf8) else { return nil }

        return (string, headerLen + len)
    }

    /// Read a CBOR byte string
    private func readCBORByteString(bytes: [UInt8], offset: Int) -> (Data, Int)? {
        guard offset < bytes.count else { return nil }
        let firstByte = bytes[offset]

        // Byte string (0x40-0x5f for small, 0x58-0x5b for larger)
        guard (firstByte & 0xe0) == 0x40 else { return nil }

        let (length, headerLen) = cborLength(firstByte: firstByte, bytes: bytes, offset: offset)
        guard let len = length else { return nil }

        let start = offset + headerLen
        guard start + len <= bytes.count else { return nil }

        return (Data(bytes[start..<start + len]), headerLen + len)
    }

    /// Get length from CBOR header
    private func cborLength(firstByte: UInt8, bytes: [UInt8], offset: Int) -> (Int?, Int) {
        let additional = Int(firstByte & 0x1f)

        if additional < 24 {
            return (additional, 1)
        } else if additional == 24 {
            guard offset + 1 < bytes.count else { return (nil, 0) }
            return (Int(bytes[offset + 1]), 2)
        } else if additional == 25 {
            guard offset + 2 < bytes.count else { return (nil, 0) }
            return (Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]), 3)
        } else if additional == 26 {
            guard offset + 4 < bytes.count else { return (nil, 0) }
            let len = Int(bytes[offset + 1]) << 24 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
            return (len, 5)
        }

        return (nil, 0)
    }

    /// Read a signed CBOR integer.
    private func readCBORInteger(bytes: [UInt8], offset: Int) -> (Int, Int)? {
        guard offset < bytes.count else { return nil }
        let firstByte = bytes[offset]
        let majorType = (firstByte & 0xe0) >> 5
        guard majorType == 0 || majorType == 1 else { return nil }
        let (magnitude, headerLength) = cborLength(firstByte: firstByte, bytes: bytes, offset: offset)
        guard let magnitude else { return nil }
        let value = majorType == 0 ? magnitude : -1 - magnitude
        return (value, headerLength)
    }

    /// Skip a CBOR item and return its length
    private func skipCBORItem(bytes: [UInt8], offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let firstByte = bytes[offset]
        let majorType = (firstByte & 0xe0) >> 5

        switch majorType {
        case 0, 1:  // Unsigned/negative integer
            let (_, headerLen) = cborLength(firstByte: firstByte, bytes: bytes, offset: offset)
            return headerLen

        case 2, 3:  // Byte/text string
            let (length, headerLen) = cborLength(firstByte: firstByte, bytes: bytes, offset: offset)
            guard let len = length else { return nil }
            return headerLen + len

        case 4:  // Array
            let (length, headerLen) = cborLength(firstByte: firstByte, bytes: bytes, offset: offset)
            guard let arrayLen = length else { return nil }
            var total = headerLen
            for _ in 0..<arrayLen {
                guard let itemLen = skipCBORItem(bytes: bytes, offset: offset + total) else { return nil }
                total += itemLen
            }
            return total

        case 5:  // Map
            let (length, headerLen) = cborLength(firstByte: firstByte, bytes: bytes, offset: offset)
            guard let mapLen = length else { return nil }
            var total = headerLen
            for _ in 0..<(mapLen * 2) {
                guard let itemLen = skipCBORItem(bytes: bytes, offset: offset + total) else { return nil }
                total += itemLen
            }
            return total

        case 7:  // Simple/float
            let additional = Int(firstByte & 0x1f)
            if additional < 24 {
                return 1
            } else if additional == 24 {
                return 2
            } else if additional == 25 {
                return 3
            } else if additional == 26 {
                return 5
            } else if additional == 27 {
                return 9
            }
            return 1

        default: return nil
        }
    }

    /// Extract EC point from COSE-encoded key
    /// COSE EC2 key structure: { 1: kty, 3: alg, -1: crv, -2: x, -3: y }
    private func extractECPointFromCOSE(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0

        // Expect map
        guard offset < bytes.count else { return nil }
        let firstByte = bytes[offset]
        guard (firstByte & 0xe0) == 0xa0 else { return nil }

        let mapSize = Int(firstByte & 0x1f)
        offset += 1

        var x: Data?
        var y: Data?
        var keyType: Int?
        var algorithm: Int?
        var curve: Int?

        for _ in 0..<mapSize {
            // Read key (negative integers use major type 1)
            guard offset < bytes.count else { return nil }
            let keyByte = bytes[offset]

            let key: Int
            if (keyByte & 0xe0) == 0x00 {
                // Positive integer
                key = Int(keyByte & 0x1f)
                offset += 1
            } else if (keyByte & 0xe0) == 0x20 {
                // Negative integer: -1 - value
                key = -1 - Int(keyByte & 0x1f)
                offset += 1
            } else {
                // Skip unknown key type
                guard let skipLen = skipCBORItem(bytes: bytes, offset: offset) else { return nil }
                offset += skipLen
                guard let skipLen2 = skipCBORItem(bytes: bytes, offset: offset) else { return nil }
                offset += skipLen2
                continue
            }

            // Read value based on key
            switch key {
            case 1:  // kty
                guard let (value, len) = readCBORInteger(bytes: bytes, offset: offset) else { return nil }
                keyType = value
                offset += len

            case 3:  // alg
                guard let (value, len) = readCBORInteger(bytes: bytes, offset: offset) else { return nil }
                algorithm = value
                offset += len

            case -1:  // crv
                guard let (value, len) = readCBORInteger(bytes: bytes, offset: offset) else { return nil }
                curve = value
                offset += len

            case -2:  // x coordinate
                guard let (xData, len) = readCBORByteString(bytes: bytes, offset: offset) else { return nil }
                x = xData
                offset += len

            case -3:  // y coordinate
                guard let (yData, len) = readCBORByteString(bytes: bytes, offset: offset) else { return nil }
                y = yData
                offset += len

            default:
                // Skip other values
                guard let skipLen = skipCBORItem(bytes: bytes, offset: offset) else { return nil }
                offset += skipLen
            }
        }

        // Build uncompressed EC point: 0x04 || x || y
        guard keyType == 2, algorithm == -7, curve == 1 else {
            Self.logger.error("Unsupported COSE key parameters: kty=\(keyType ?? -1), alg=\(algorithm ?? 0), crv=\(curve ?? -1)")
            return nil
        }

        guard let xCoord = x, let yCoord = y, xCoord.count == 32, yCoord.count == 32 else {
            Self.logger.error("Missing or invalid P-256 coordinates in COSE key")
            return nil
        }

        // Uncompressed point format
        var point = Data([0x04])
        point.append(xCoord)
        point.append(yCoord)

        return point
    }

    /// Map ASAuthorizationError to AppleFIDO2Error
    private func mapAuthorizationError(_ error: Error) -> AppleFIDO2Error {
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled: return .cancelled
            case .invalidResponse:
                return .invalidCredential(
                    String(localized: "Invalid response from credential provider.", comment: "Passkey/security-key registration error detail"))
            case .notHandled: return currentBacking.isPasskey ? .passkeyUnavailable : .noSecurityKey
            case .failed: return .registrationFailed(authError.localizedDescription)
            case .notInteractive:
                return .registrationFailed(String(localized: "User interaction is required.", comment: "Passkey/security-key registration error detail"))
            case .matchedExcludedCredential:
                return .registrationFailed(
                    String(localized: "A matching credential already exists.", comment: "Passkey/security-key registration error detail"))
            case .credentialImport:
                return .registrationFailed(String(localized: "Credential import is not supported.", comment: "Passkey/security-key registration error detail"))
            case .credentialExport:
                return .registrationFailed(String(localized: "Credential export is not supported.", comment: "Passkey/security-key registration error detail"))
            case .preferSignInWithApple:
                return .registrationFailed(String(localized: "Sign in with Apple was preferred.", comment: "Passkey/security-key registration error detail"))
            case .deviceNotConfiguredForPasskeyCreation: return .passkeyUnavailable
            case .unknown: return .authServicesError(authError.localizedDescription)
            @unknown default: return .authServicesError(authError.localizedDescription)
            }
        }

        return .authServicesError(error.localizedDescription)
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AppleFIDO2KeyGenerator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            // Return the stored anchor or find the key window
            if let anchor = self.presentationAnchor { return anchor }

            // Fallback: find the key window
            #if os(iOS) || os(visionOS)
            if let window = UIApplication.shared.deviceKeyWindow {
                return window
            }
            #endif

            // Last resort: create a new window
            #if os(iOS) || os(visionOS)
            return UIWindow()
            #else
            return NSWindow()
            #endif
        }
    }
}

// MARK: - Fingerprint Calculation

extension AppleFIDO2CredentialInfo {
    /// Calculate SHA256 fingerprint of the public key
    var fingerprint: String {
        let hash = SHA256.hash(data: publicKeySSH)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
