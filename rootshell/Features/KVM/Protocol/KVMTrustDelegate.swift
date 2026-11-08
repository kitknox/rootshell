//
//  KVMTrustDelegate.swift
//  rootshell
//
//  Server-trust handling for one KVM session's URLSession. Comet units
//  ship a self-signed certificate, so an untrusted chain goes to the same
//  trust-on-first-use prompt Screen Sharing uses for VeNCrypt, keyed by the
//  real host even when traffic rides the loopback tunnel bridge.
//

import CryptoKit
import Foundation
import Security
import os
import RFBTransport
import rootshellVNC

nonisolated final class KVMTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "KVM")

    private let host: String
    private let port: UInt16
    /// Platform trust can only vouch for the real hostname, never the bridge.
    private let evaluatesPlatformTrust: Bool
    private let validate: VNCConfiguration.CertificateValidationHandler?

    private let lock = NSLock()
    private var acceptedFingerprint: String?
    private var pendingDecision: Task<Bool, Never>?

    init(
        host: String,
        port: UInt16,
        evaluatesPlatformTrust: Bool,
        validate: VNCConfiguration.CertificateValidationHandler?
    ) {
        self.host = host
        self.port = port
        self.evaluatesPlatformTrust = evaluatesPlatformTrust
        self.validate = validate
    }

    /// SHA-256 of the accepted leaf, for Connection Info.
    var trustedFingerprint: String? {
        lock.withLock { acceptedFingerprint }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await handle(challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await handle(challenge)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let der = chain.map { SecCertificateCopyData($0) as Data }
        guard let leaf = der.first else { return (.cancelAuthenticationChallenge, nil) }
        let fingerprint = Self.fingerprint(leaf)

        let platformTrusted = evaluatesPlatformTrust && Self.platformTrusts(trust, host: host)
        let accepted = await decide(chain: der, fingerprint: fingerprint, platformTrusted: platformTrusted)
        return accepted ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    private static func platformTrusts(_ trust: SecTrust, host: String) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// One decision at a time, so parallel REST and WebSocket connections
    /// share a single prompt. A fingerprint change mid-session is refused.
    private func decide(chain: [Data], fingerprint: String, platformTrusted: Bool) async -> Bool {
        while true {
            let (known, pending): (String?, Task<Bool, Never>?) = lock.withLock {
                (acceptedFingerprint, pendingDecision)
            }
            if let known {
                if known != fingerprint {
                    Self.logger.error("KVM certificate changed during the session; refusing")
                }
                return known == fingerprint
            }
            if let pending {
                _ = await pending.value
                continue
            }
            let task = Task { [self] in
                platformTrusted ? true : await askUser(chain: chain)
            }
            lock.withLock { pendingDecision = task }
            let accepted = await task.value
            lock.withLock {
                pendingDecision = nil
                if accepted { acceptedFingerprint = fingerprint }
            }
            return accepted
        }
    }

    private func askUser(chain: [Data]) async -> Bool {
        guard let validate else { return false }
        let request = VNCConfiguration.CertificateValidationRequest(
            host: host,
            port: port,
            certificateChainDER: chain)
        switch await validate(request) {
        case .acceptOnce, .acceptAndStore:
            return true
        case .reject:
            return false
        }
    }

    static func fingerprint(_ certificate: Data) -> String {
        SHA256.hash(data: certificate)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}
