//
//  VPNPeerTrust.swift
//  rootshell (Catalyst, Standalone) + rootshellvpn (VPN host)
//
//  Code-signing peer validation for the VPN control socket. The App Group
//  socket path is writable by any same-user process, so filesystem permissions
//  alone authenticate nothing: a malicious process could pre-bind the path and
//  impersonate the host (capturing the resolved SSH credentials that startVPN
//  carries), or connect to the real host and drive the tunnel. Both ends
//  therefore verify the peer's code signature — resolved from the
//  kernel-provided audit token, never from anything the peer reports about
//  itself — before exchanging any payload.
//

#if os(macOS) || (targetEnvironment(macCatalyst) && STANDALONE)

import Foundation
import Darwin
import Security

enum VPNPeerTrust {
    /// Apple-anchored chain + our team: matches Developer ID, Apple
    /// Development, and App Store signing (subject.OU carries the team ID in
    /// all three), and nothing an attacker can obtain.
    ///
    /// Left as a literal: unlike the bundle identifier, a contributor's team
    /// can't be recovered from this process without reading its own signature.
    /// Under a signing override the pair this gates -- a team-signed rootshell
    /// talking to a team-signed rootshellvpn -- would fail this check, but
    /// rootshellvpn doesn't build at all (see docs/contributor-signing.md), so
    /// nothing reaches it today. Worth revisiting alongside the rest of the
    /// VPN feature.
    private nonisolated static let teamRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"D97ZME3ET2\""

    /// This process's own org-identifier prefix, recovered from its own bundle
    /// identifier by stripping whichever product suffix Xcode appended (see
    /// Configuration/Identity.xcconfig's PRODUCT_BUNDLE_IDENTIFIER
    /// derivation). Works whether this code is running inside rootshell or
    /// rootshellvpn, and needs no Info.plist plumbing of its own -- neither
    /// target's identifier takes a variant suffix, since the China build
    /// excludes every VPN source file.
    private nonisolated static let orgIdentifierPrefix: String = {
        guard let id = Bundle.main.bundleIdentifier else { return "com.kk2" }
        for suffix in [".rootshellvpn", ".rootshell"] where id.hasSuffix(suffix) {
            return String(id.dropLast(suffix.count))
        }
        return "com.kk2"
    }()

    /// The Catalyst app — the only legitimate control-socket client.
    nonisolated static let appClientRequirement =
        "identifier \"\(orgIdentifierPrefix).rootshell\" and \(teamRequirement)"

    /// The VPN host agent — the only legitimate control-socket server.
    nonisolated static let hostServerRequirement =
        "identifier \"\(orgIdentifierPrefix).rootshellvpn\" and \(teamRequirement)"

    /// True when the process on the other end of the connected unix socket
    /// satisfies `requirement`. Works from either end (the kernel caches peer
    /// credentials on both pcbs at connect time). Fails closed on any error.
    nonisolated static func isPeerTrusted(fd: Int32, requirement: String) -> Bool {
        var token = audit_token_t()
        var tokenLen = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLen) == 0,
              tokenLen == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return false
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData]
        guard let peerCode = copyGuest(attributes: attributes as CFDictionary) else {
            return false
        }

        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &parsed) == errSecSuccess,
              let parsedRequirement = parsed else {
            return false
        }

        return SecCodeCheckValidity(peerCode, SecCSFlags(), parsedRequirement) == errSecSuccess
    }

    /// Peer pid for reject-path logging only — never for trust decisions
    /// (pids are reusable; the audit token above is not). 0 when unavailable.
    nonisolated static func peerPID(fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return 0 }
        return pid
    }

    // MARK: - Audit token → SecCode

    #if os(macOS)

    private nonisolated static func copyGuest(attributes: CFDictionary) -> SecCode? {
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &peer) == errSecSuccess else {
            return nil
        }
        return peer
    }

    #else

    // The Catalyst SDK view of Security hides SecCodeCopyGuestWithAttributes
    // (everything else this file needs is visible), but the symbol is exported
    // by the macOS Security.framework every Catalyst process links, so resolve
    // it at runtime. Standalone-only code — never in an App Store submission.
    private typealias CopyGuestFn = @convention(c) (
        SecCode?, CFDictionary?, SecCSFlags, UnsafeMutablePointer<Unmanaged<SecCode>?>
    ) -> OSStatus

    private nonisolated static let copyGuestFn: CopyGuestFn? = {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let sym = dlsym(security, "SecCodeCopyGuestWithAttributes") else {
            return nil
        }
        return unsafeBitCast(sym, to: CopyGuestFn.self)
    }()

    private nonisolated static func copyGuest(attributes: CFDictionary) -> SecCode? {
        guard let fn = copyGuestFn else { return nil }
        var peer: Unmanaged<SecCode>?
        guard fn(nil, attributes, SecCSFlags(), &peer) == errSecSuccess else { return nil }
        return peer?.takeRetainedValue()
    }

    #endif
}

#endif
