//
//  AppleFIDO2Signer.swift
//  rootshell
//
//  WebAuthn signing via Apple AuthenticationServices.
//  Routes assertions to an external security key or the platform passkey store.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import AuthenticationServices
import CryptoKit
import Foundation
import os.log

/// Performs FIDO2 signing operations using Apple AuthenticationServices
/// This enables cross-platform FIDO2 support (iOS, iPadOS, Mac Catalyst)
/// with automatic transport handling (USB-C, NFC, Lightning)
@MainActor final class AppleFIDO2Signer: NSObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AppleFIDO2Signer")

    /// Current operation state for UI feedback (use Swift 6 Observation instead of Combine)
    private(set) var state: AppleFIDO2State = .idle

    /// Continuation for async/await bridge
    private var signContinuation: CheckedContinuation<AppleFIDO2SignatureResult, Error>?

    /// Credential store selected for the in-flight assertion.
    private var currentBacking: AppleFIDO2CredentialBacking = .securityKey

    /// Presentation anchor for authorization UI
    private weak var presentationAnchor: ASPresentationAnchor?

    /// Retain the controller for the duration of the async operation.
    private var authorizationController: ASAuthorizationController?

    override init() { super.init() }

    /// Set the presentation anchor for the authorization UI
    /// - Parameter anchor: The window to present the authorization UI from
    func setPresentationAnchor(_ anchor: ASPresentationAnchor?) { self.presentationAnchor = anchor }

    /// Sign data using a FIDO2 credential via Apple AuthenticationServices
    ///
    /// This method:
    /// 1. Creates an assertion request with the credential ID
    /// 2. Presents the system authorization UI
    /// 3. Returns the signature, flags, and counter from the authenticator
    ///
    /// - Parameters:
    ///   - credentialID: The credential ID from registration
    ///   - challenge: The challenge to sign (typically SHA256 of SSH session data)
    /// - Returns: The signature result containing signature, flags, and counter
    /// - Throws: AppleFIDO2Error if signing fails
    func sign(credentialID: Data, backing: AppleFIDO2CredentialBacking, challenge: Data) async throws -> AppleFIDO2SignatureResult {
        Self.logger.info("Starting WebAuthn assertion for credential: \(credentialID.prefix(16).base64EncodedString())..., backing: \(backing.rawValue)")

        state = .waitingForSecurityKey(operation: String(localized: "Signing", comment: "WebAuthn assertion progress"))
        currentBacking = backing

        let authorizationRequest: ASAuthorizationRequest
        switch backing {
        case .securityKey:
            // visionOS ships no external security-key support, only platform passkeys.
            #if os(visionOS)
            state = .failed(AppleFIDO2Error.platformNotSupported.localizedDescription)
            throw AppleFIDO2Error.platformNotSupported
            #else
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: AppleFIDO2CredentialInfo.sshRpID)
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            let descriptor = ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                credentialID: credentialID, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
            request.allowedCredentials = [descriptor]
            request.userVerificationPreference = .discouraged
            authorizationRequest = request
            #endif

        case .platformPasskey:
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: AppleFIDO2CredentialInfo.sshRpID)
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            request.allowedCredentials = [ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialID)]
            request.userVerificationPreference = .required
            authorizationRequest = request
        }

        // Create and configure the authorization controller
        let authController = ASAuthorizationController(authorizationRequests: [authorizationRequest])
        authController.delegate = self
        authController.presentationContextProvider = self
        authorizationController = authController

        return try await withCheckedThrowingContinuation { continuation in
            self.signContinuation = continuation
            authController.performRequests()
        }
    }

    /// Sign SSH session data for authentication
    ///
    /// This is the main entry point for SSH authentication. It:
    /// 1. Computes SHA256 of the session data (as per SSH SK spec)
    /// 2. Calls the FIDO2 assertion
    /// 3. Formats the result for SSH wire format
    ///
    /// - Parameters:
    ///   - credentialID: The credential ID
    ///   - sessionData: The SSH session data to sign
    /// - Returns: The signature result
    /// - Throws: AppleFIDO2Error if signing fails
    func signSSHData(credentialID: Data, backing: AppleFIDO2CredentialBacking, sessionData: Data) async throws -> AppleFIDO2SignatureResult {
        // Pass the session data directly as the challenge
        // WebAuthn will compute SHA256 internally as part of clientDataHash
        // The signature is over: authenticator_data || SHA256(challenge)
        return try await sign(credentialID: credentialID, backing: backing, challenge: sessionData)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AppleFIDO2Signer: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            Self.logger.info("Authorization completed successfully")

            guard let credential = authorization.credential as? any ASAuthorizationPublicKeyCredentialAssertion,
                credentialMatchesCurrentBacking(authorization.credential)
            else {
                Self.logger.error("Unexpected credential type")
                state = .failed(String(localized: "Unexpected credential type", comment: "WebAuthn assertion status error"))
                finishSigning(
                    with: .failure(
                        AppleFIDO2Error.invalidCredential(
                            String(localized: "Credential provider returned the wrong assertion type.", comment: "Passkey/security-key signing error detail"))))
                return
            }

            // Extract the signature and authenticator data
            guard let signature = credential.signature, let authenticatorData = credential.rawAuthenticatorData else {
                Self.logger.error("Missing signature or authenticator data in credential")
                state = .failed(String(localized: "Missing required credential data", comment: "WebAuthn assertion status error"))
                finishSigning(
                    with: .failure(
                        AppleFIDO2Error.assertionFailed(
                            String(localized: "Missing signature or authenticator data.", comment: "Passkey/security-key signing error detail"))))
                return
            }

            // clientDataJSON is non-optional in ASAuthorizationSecurityKeyPublicKeyCredentialAssertion
            let clientDataJSON = credential.rawClientDataJSON

            let sigSize = signature.count
            let authDataSize = authenticatorData.count
            let clientDataSize = clientDataJSON.count
            Self.logger.info("Got signature (\(sigSize) bytes), authenticator data (\(authDataSize) bytes), clientData (\(clientDataSize) bytes)")

            let result = AppleFIDO2SignatureResult(signature: signature, authenticatorData: authenticatorData, clientDataJSON: clientDataJSON)

            state = .success
            finishSigning(with: .success(result))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            Self.logger.error("Authorization failed: \(error.localizedDescription)")

            let appleFIDO2Error = mapAuthorizationError(error)
            state = .failed(appleFIDO2Error.errorDescription ?? "Unknown error")
            finishSigning(with: .failure(appleFIDO2Error))
        }
    }

    private func credentialMatchesCurrentBacking(_ credential: any ASAuthorizationCredential) -> Bool {
        switch currentBacking {
        case .securityKey:
            #if os(visionOS)
            return false
            #else
            return credential is ASAuthorizationSecurityKeyPublicKeyCredentialAssertion
            #endif
        case .platformPasskey: return credential is ASAuthorizationPlatformPublicKeyCredentialAssertion
        }
    }

    private func finishSigning(with result: Result<AppleFIDO2SignatureResult, Error>) {
        let continuation = signContinuation
        signContinuation = nil
        authorizationController = nil
        continuation?.resume(with: result)
    }

    /// Map ASAuthorizationError to AppleFIDO2Error
    private func mapAuthorizationError(_ error: Error) -> AppleFIDO2Error {
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled: return .cancelled
            case .invalidResponse:
                return .invalidCredential(String(localized: "Invalid response from credential provider.", comment: "Passkey/security-key signing error detail"))
            case .notHandled: return currentBacking.isPasskey ? .credentialNotFound : .noSecurityKey
            case .failed: return .assertionFailed(authError.localizedDescription)
            case .notInteractive:
                return .assertionFailed(String(localized: "User interaction is required.", comment: "Passkey/security-key signing error detail"))
            case .unknown: return .authServicesError(authError.localizedDescription)
            case .matchedExcludedCredential:
                return .invalidCredential(String(localized: "Credential was excluded.", comment: "Passkey/security-key signing error detail"))
            case .credentialImport:
                return .assertionFailed(String(localized: "Credential import failed.", comment: "Passkey/security-key signing error detail"))
            case .credentialExport:
                return .assertionFailed(String(localized: "Credential export failed.", comment: "Passkey/security-key signing error detail"))
            case .preferSignInWithApple:
                return .authServicesError(
                    String(localized: "Sign in with Apple is required for this credential.", comment: "Passkey/security-key signing error detail"))
            case .deviceNotConfiguredForPasskeyCreation: return currentBacking.isPasskey ? .passkeyUnavailable : .noSecurityKey
            @unknown default: return .authServicesError(authError.localizedDescription)
            }
        }

        return .authServicesError(error.localizedDescription)
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AppleFIDO2Signer: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Return the stored anchor or find the key window
        if let anchor = presentationAnchor { return anchor }

        // Fallback: find the key window
        #if os(iOS) || os(visionOS)
        if let window = UIApplication.shared.deviceKeyWindow {
            return window
        }
        #endif

        // Last resort: create a new window (shouldn't happen in practice)
        #if os(iOS) || os(visionOS)
        return UIWindow()
        #else
        return NSWindow()
        #endif
    }
}
