#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation
import Darwin
import Security
import os.log

nonisolated struct LocalAgentPeerIdentity: Sendable, Equatable {
    var pid: pid_t
    var path: String
    var signingIdentifier: String?
    var teamID: String?
    var isPlatformBinary: Bool
    var isAdHoc: Bool
    var cdhash: Data?
    var signatureValid: Bool

    var displayName: String {
        if let pathURL = URL(string: "file://\(path)") {
            return pathURL.lastPathComponent
        }
        return path.isEmpty ? "Unknown Process" : (path as NSString).lastPathComponent
    }

    var identityLine: String {
        if isPlatformBinary {
            return signingIdentifier.map {
                String(localized: "Apple system binary · \($0)", comment: "Local SSH agent client identity line for Apple platform binary")
            } ?? String(localized: "Apple system binary", comment: "Local SSH agent client identity line for Apple platform binary")
        }
        if let teamID, let signingIdentifier {
            return String(localized: "Team \(teamID) · \(signingIdentifier)", comment: "Local SSH agent client identity line for team-signed binary")
        }
        if isAdHoc {
            return String(localized: "Ad-hoc signed", comment: "Local SSH agent client identity line for ad-hoc signed binary")
        }
        if signatureValid {
            return signingIdentifier ?? String(localized: "Signed process", comment: "Local SSH agent client identity line for signed process")
        }
        return String(localized: "Unsigned or unverified process", comment: "Local SSH agent client identity line for unsigned process")
    }

    var ruleKey: LocalAgentClientKey? {
        if isPlatformBinary, let signingIdentifier {
            return .platform(signingID: signingIdentifier)
        }
        if let teamID, let signingIdentifier {
            return .team(teamID: teamID, signingID: signingIdentifier)
        }
        if signatureValid, isAdHoc, let cdhash {
            return .cdhash(cdhash)
        }
        return nil
    }

    static func unresolved(pid: pid_t = 0) -> LocalAgentPeerIdentity {
        LocalAgentPeerIdentity(
            pid: pid,
            path: "",
            signingIdentifier: nil,
            teamID: nil,
            isPlatformBinary: false,
            isAdHoc: false,
            cdhash: nil,
            signatureValid: false
        )
    }
}

enum LocalAgentPeerResolver {
    private static let logger = Logger(subsystem: "com.rootshell", category: "LocalAgentPeer")

    nonisolated static func resolve(fd: Int32) -> LocalAgentPeerIdentity {
        let pid = peerPID(fd: fd)
        var token = audit_token_t()
        var tokenLen = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLen) == 0,
              tokenLen == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return .unresolved(pid: pid)
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData]
        guard let code = copyGuest(attributes: attributes as CFDictionary) else {
            return .unresolved(pid: pid)
        }

        let signatureValid = SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
        let isPlatform = isAppleAnchored(code)

        var staticCode: SecStaticCode?
        let staticCodeRef: SecStaticCode?
        if SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess {
            staticCodeRef = staticCode
        } else {
            staticCodeRef = nil
        }

        let path = staticCodeRef.flatMap { copyPath(staticCode: $0) } ?? procPath(pid: pid) ?? ""

        var signingIdentifier: String?
        var teamID: String?
        var cdhash: Data?
        var isAdHoc = false

        if let staticCodeRef {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(
                staticCodeRef,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &info
            ) == errSecSuccess,
               let dict = info as? [String: Any] {
                signingIdentifier = dict[kSecCodeInfoIdentifier as String] as? String
                teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
                cdhash = dict[kSecCodeInfoUnique as String] as? Data
                if let flags = dict[kSecCodeInfoFlags as String] as? NSNumber {
                    isAdHoc = (flags.uint32Value & 0x00000002) != 0
                }
            }
        }

        return LocalAgentPeerIdentity(
            pid: pid,
            path: path,
            signingIdentifier: signingIdentifier,
            teamID: teamID,
            isPlatformBinary: isPlatform,
            isAdHoc: isAdHoc,
            cdhash: cdhash,
            signatureValid: signatureValid
        )
    }

    nonisolated static func peerPID(fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return 0 }
        return pid
    }

    nonisolated static func isDescendedFromRootshell(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        let helperPID = HelperConnection.currentHelperProcessID
        let appPID = getpid()
        var current = pid
        var seen = Set<pid_t>()

        for _ in 0..<64 {
            if current == helperPID && helperPID > 0 { return true }
            if current == appPID { return true }
            if current <= 1 || seen.contains(current) { return false }
            if isRootshellHelperProcess(pid: current) { return true }
            seen.insert(current)
            guard let parent = parentPID(of: current), parent > 0 else { return false }
            current = parent
        }
        return false
    }

    // MARK: - SecCode audit token shim

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

    private nonisolated static func copyPath(staticCode: SecStaticCode) -> String? {
        var cfURL: CFURL?
        guard SecCodeCopyPath(staticCode, SecCSFlags(), &cfURL) == errSecSuccess,
              let url = cfURL as URL? else {
            return nil
        }
        return url.path
    }

    private nonisolated static func isAppleAnchored(_ code: SecCode) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    // MARK: - proc helpers

    private typealias ProcPidPathFn = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias ProcPidInfoFn = @convention(c) (Int32, Int32, UInt64, UnsafeMutableRawPointer, Int32) -> Int32

    private nonisolated static let procPidPathFn: ProcPidPathFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") else { return nil }
        return unsafeBitCast(sym, to: ProcPidPathFn.self)
    }()

    private nonisolated static let procPidInfoFn: ProcPidInfoFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidinfo") else { return nil }
        return unsafeBitCast(sym, to: ProcPidInfoFn.self)
    }()

    private nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        guard let procPidInfoFn else { return nil }
        var info = [UInt8](repeating: 0, count: 256)
        let rc = info.withUnsafeMutableBytes { ptr in
            procPidInfoFn(pid, 3, 0, ptr.baseAddress!, Int32(ptr.count))
        }
        guard rc >= 20 else { return nil }
        let ppid =
            UInt32(info[16]) |
            (UInt32(info[17]) << 8) |
            (UInt32(info[18]) << 16) |
            (UInt32(info[19]) << 24)
        return pid_t(ppid)
    }

    private nonisolated static func procPath(pid: pid_t) -> String? {
        guard let procPidPathFn else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes {
            procPidPathFn(pid, $0.baseAddress!, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated static func isRootshellHelperProcess(pid: pid_t) -> Bool {
        guard let path = procPath(pid: pid) else { return false }
        let name = (path as NSString).lastPathComponent
        return name == "rootshell-helper"
    }
}

#endif
