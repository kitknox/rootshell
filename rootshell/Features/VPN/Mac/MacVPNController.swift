//
//  MacVPNController.swift
//  rootshell (Catalyst, Standalone)
//
//  Entry point for VPN-over-SSH on macOS. The Catalyst app can't host a packet
//  tunnel, so this launches the native `rootshellvpn.app` agent (system-extension
//  host) and drives it over the App Group control socket: activate the extension,
//  resolve the profile + secrets, start/stop the tunnel, poll status.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation
import Darwin
import os.log

@MainActor
final class MacVPNController {
    static let shared = MacVPNController()

    private let logger = Logger(subsystem: "com.rootshell", category: "MacVPNController")
    nonisolated private static let fileLogger = Logger(subsystem: "com.rootshell", category: "MacVPNController")

    /// The host agent ships inside the app bundle and is launched IN PLACE —
    /// no /Applications install. Sparkle updates the whole bundle atomically,
    /// so the bundled copy is always current (system-extension activation
    /// requires rootshell.app itself to live in /Applications). Dev builds
    /// (deploy artifact gitignored) fall back to a manually installed copy.
    nonisolated static var hostAppURL: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("rootshellvpn.app"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let installed = URL(fileURLWithPath: "/Applications/rootshellvpn.app")
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    /// Invoked when the system extension is waiting on user approval (so the app
    /// can tell the user to approve it), and when that resolves. Called on the
    /// main actor.
    var onApprovalRequired: (() -> Void)?
    var onApprovalResolved: (() -> Void)?

    /// HTTP capture engine config (with the CA key) forwarded to the sysext on
    /// every start, since it can't read the user's keychain.
    var captureConfigProvider: (() -> Data?)?

    enum MacVPNError: LocalizedError {
        case hostNotInstalled
        case hostUnreachable
        case profileNotFound
        case hostKeyNotTrusted(String)
        case activationFailed
        case activationTimedOut

        var errorDescription: String? {
            switch self {
            case .hostNotInstalled: return "The rootshell VPN helper is missing from the app bundle."
            case .hostUnreachable: return "Could not reach the rootshell VPN helper."
            case .profileNotFound: return "VPN profile not found."
            case .hostKeyNotTrusted(let host): return "No trusted SSH host key for \(host). Connect to this server in a regular SSH terminal session first so its host key can be verified and saved, then start the VPN."
            case .activationFailed: return "The VPN system extension failed to activate."
            case .activationTimedOut: return "Timed out waiting for the VPN system extension to be approved."
            }
        }
    }

    // MARK: - Host lifecycle

    /// Ensure the correct host agent is running and answering.
    ///
    /// The authoritative host is the bundled copy; a running host is "current"
    /// only when its version + bundle path match it. That self-reported info is
    /// only accepted from a peer whose code signature checked out —
    /// `VPNHostConnection` refuses to exchange anything with an unverified
    /// listener, so an impostor on the socket can't spoof it. A mismatch (stale
    /// /Applications copy, or a Sparkle update swapped the bundle under a
    /// running host) requires killing the old instance — macOS `open` reuses a
    /// running agent, so old code would silently keep serving otherwise. Never
    /// swap under a live tunnel; defer to the next idle connect instead.
    func ensureHostRunning() async throws {
        guard let hostURL = Self.hostAppURL else {
            throw MacVPNError.hostNotInstalled
        }
        let expectedVersion = Self.bundleVersion(hostURL)
        let running = await hostInfo()

        if let running, running.version == expectedVersion, running.bundlePath == hostURL.path {
            return
        }

        if running != nil {
            let connected = (await status())?.status == "connected"
            if connected {
                logger.info("stale VPN host is serving a live tunnel; deferring swap")
                return
            }
            logger.info("stale VPN host running; replacing with bundled copy")
        }

        // Unresponsive (dead or wedged) or stale: any live instance must be
        // verifiably dead before relaunch. Killing the host never drops the
        // tunnel (the sysext is an independent process).
        await terminateHost()
        launchHost(hostURL)
        try await awaitReady()
    }

    private func awaitReady() async throws {
        for _ in 0..<30 {   // ~3s
            try? await Task.sleep(for: .milliseconds(100))
            if await ping() { return }
        }
        throw MacVPNError.hostUnreachable
    }

    /// Terminate any running host agent and wait until it's actually gone,
    /// escalating SIGTERM → SIGKILL. `open` reuses a running instance, so
    /// install/relaunch must not proceed while the old process survives.
    private func terminateHost() async {
        for sig in ["TERM", "KILL"] {
            let killed = await Task.detached {
                Self.spawnAndWait("/usr/bin/killall", ["killall", "-\(sig)", "rootshellvpn"]) == 0
            }.value
            if !killed { return }   // no matching process — already gone
            for _ in 0..<10 {   // up to 2s per signal
                try? await Task.sleep(for: .milliseconds(200))
                let alive = await Task.detached { Self.hostProcessAlive() }.value
                if !alive { return }
            }
            logger.error("VPN host survived SIG\(sig, privacy: .public)")
        }
    }

    nonisolated private static func hostProcessAlive() -> Bool {
        // Signal 0 = existence check, nothing delivered.
        spawnAndWait("/usr/bin/pkill", ["pkill", "-0", "-x", "rootshellvpn"]) == 0
    }

    /// Spawn a tool and return its exit status (-1 on spawn/abnormal exit).
    nonisolated private static func spawnAndWait(_ path: String, _ argv: [String]) -> Int32 {
        var pid: pid_t = 0
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        guard posix_spawn(&pid, path, nil, nil, cArgs, environ) == 0 else { return -1 }
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid, (status & 0x7f) == 0 else { return -1 }
        return (status >> 8) & 0xff
    }

    nonisolated private static func bundleVersion(_ appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleVersion"] as? String
    }

    private func launchHost(_ hostURL: URL) {
        Task.detached {
            let rc = Self.spawnAndWait("/usr/bin/open", ["open", hostURL.path])
            if rc != 0 { Self.fileLogger.error("failed to launch host: \(rc)") }
        }
    }

    // MARK: - Control

    /// Activate the system extension and wait until it's live. Non-blocking on
    /// the host: it returns immediately and we poll `extensionStatus`, surfacing
    /// approval-needed to the UI (the host opens System Settings). All the waiting
    /// happens via async sleeps + off-actor socket I/O, so the UI never blocks.
    func activateExtension() async throws {
        try await ensureHostRunning()
        _ = try await send(VPNControlRequest(command: .activateExtension))

        var announcedApproval = false
        // Resolved on every exit (success, failure, timeout, cancellation).
        defer { if announcedApproval { onApprovalResolved?() } }
        for _ in 0..<300 {   // up to ~5 min
            switch await extensionStatus()?.state {
            case .activated:
                return
            case .awaitingApproval:
                if !announcedApproval { announcedApproval = true; onApprovalRequired?() }
            case .failed:
                throw MacVPNError.activationFailed
            default:
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw MacVPNError.activationTimedOut
    }

    /// Fast liveness probe (2s timeout), off-main. Lets cold-start restore skip
    /// status queries — and their error logging — when no host is running.
    func isHostResponsive() async -> Bool { await ping() }

    func extensionStatus() async -> VPNExtensionStatusResponse? {
        guard let response = try? await send(VPNControlRequest(command: .extensionStatus)),
              let payload = response.payload else { return nil }
        return try? JSONDecoder().decode(VPNExtensionStatusResponse.self, from: payload)
    }

    func start(profileID: UUID) async throws {
        guard let stored = VPNSharedProfileStore.profile(id: profileID) else {
            throw MacVPNError.profileNotFound
        }
        let snapshot = try Self.pinningHostKeys(stored)
        let resolved = try await Self.resolveCredentials(snapshot)
        let payload = try VPNCredentialResolver.encode(resolved)

        let request = VPNStartRequest(
            profileID: profileID,
            transportType: snapshot.transportType == .tssh && snapshot.jumpHost?.tsshRelay != nil ? "tssh-relay" : snapshot.transportType.rawValue,
            resolvedConfig: payload,
            usesAgentSigning: Self.usesAgentSigning(resolved),
            captureConfig: captureConfigProvider?()
        )
        let body = try JSONEncoder().encode(request)

        try await ensureHostRunning()
        if snapshot.transportType == .tssh, snapshot.jumpHost?.tsshRelay != nil,
           await hostInfo()?.supportsTSSHRelay != true {
            throw VPNHostConnectionError.requestFailed("Update the rootshell VPN host and system extension before using tssh jump relay.")
        }
        try await requireMultiHopSupport(snapshot)
        let response = try await send(VPNControlRequest(command: .startVPN, payload: body))
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "start failed")
        }
    }

#if !CHINA_BUILD
    /// Starts the Tailscale tunnel. The sysext can't read the app group, so the
    /// settings and the SSH egress host (with resolved secrets) travel in the
    /// start request. `restart` reconnects a running one so new settings apply.
    /// `exportOnly` brings the sysext up without Tailscale so the app can read
    /// the node state.
    func startTailnet(restart: Bool, exportOnly: Bool = false) async throws {
        let settings = VPNTailnetProfile.settings()
        var tailnet = VPNResolvedTailnet(settings: settings)
        if exportOnly {
            tailnet.exportOnly = true
        } else {
            tailnet.importState = TailnetStateHandoff.stateForVPN()
            tailnet.authKey = TailnetAuthKey.read()
        }
        var usesAgentSigning = false
        if !exportOnly, settings.sshEgressProfileID != nil {
            guard let stored = VPNTailnetProfile.egressSnapshot(settings) else {
                throw MacVPNError.profileNotFound
            }
            let egress = try Self.pinningHostKeys(stored)
            let resolved = try await Self.resolveCredentials(egress)
            tailnet.egress = egress
            tailnet.egressCredential = resolved.credential
            tailnet.egressJumpCredential = resolved.jumpCredential
            tailnet.egressExtraJumpCredentials = resolved.extraJumpCredentials
            usesAgentSigning = Self.usesAgentSigning(resolved)
        }
        let config = VPNResolvedConfig(snapshot: VPNTailnetProfile.snapshot(), credential: nil, jumpCredential: nil, tailnet: tailnet)
        let request = VPNStartRequest(
            profileID: VPNTailnetProfile.id,
            transportType: VPNSharedTransportType.tailscale.rawValue,
            resolvedConfig: try VPNCredentialResolver.encode(config),
            usesAgentSigning: usesAgentSigning,
            captureConfig: captureConfigProvider?()
        )

        try await ensureHostRunning()
        if await hostInfo()?.supportsTailscale != true {
            throw VPNHostConnectionError.requestFailed("Update the rootshell VPN host and system extension before using Tailscale.")
        }
        if let egress = tailnet.egress { try await requireMultiHopSupport(egress) }
        // The host treats a start for the running profile as a no-op.
        if restart, let current = await status(), current.profileID == VPNTailnetProfile.id,
           ["connected", "connecting", "reasserting"].contains(current.status) {
            _ = try await send(VPNControlRequest(command: .stopVPN))
            for _ in 0..<50 {   // ~10s
                try? await Task.sleep(for: .milliseconds(200))
                let state = await status()?.status
                if state == "disconnected" || state == "invalid" { break }
            }
        }
        let response = try await send(VPNControlRequest(command: .startVPN, payload: try JSONEncoder().encode(request)))
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "start failed")
        }
        guard !exportOnly else { return }
        TailnetStateHandoff.vpnDidStart()
        // The root sysext can't write the app group; record what it started with.
        VPNTailnetProfile.storeApplied(settings)
    }

    /// The host and sysext can move Tailscale node state to and from the app.
    func supportsTailnetStateHandoff() async -> Bool {
        await hostInfo()?.supportsTailnetStateHandoff == true
    }
#endif

    /// Pins fresh host keys / trusted host CAs from the app's stores
    /// (unreachable from the root sysext) and refuses to start when neither
    /// exists. The sysext verifies the server against these on connect.
    private static func pinningHostKeys(_ input: VPNSharedProfileSnapshot) throws -> VPNSharedProfileSnapshot {
        var snapshot = input
        let known = KnownHostsManager.shared.getHost(hostname: snapshot.host, port: snapshot.port)
        let caKeys = HostCAManager.shared.trustedCAOpenSSHKeys(forHost: snapshot.host)
        guard known != nil || !caKeys.isEmpty else {
            throw MacVPNError.hostKeyNotTrusted(snapshot.host)
        }
        snapshot.hostKey = known.map(VPNPinnedHostKey.init)
        snapshot.trustedCAKeys = caKeys.isEmpty ? nil : caKeys
        let chain = try snapshot.jumpChain.map { input in
            var jump = input
            let jumpKnown = KnownHostsManager.shared.getHost(hostname: jump.host, port: jump.port)
            let jumpCAKeys = HostCAManager.shared.trustedCAOpenSSHKeys(forHost: jump.host)
            guard jumpKnown != nil || !jumpCAKeys.isEmpty else {
                throw MacVPNError.hostKeyNotTrusted(jump.host)
            }
            jump.hostKey = jumpKnown.map(VPNPinnedHostKey.init)
            jump.trustedCAKeys = jumpCAKeys.isEmpty ? nil : jumpCAKeys
            return jump
        }
        snapshot.jumpHost = chain.first
        snapshot.extraJumpHosts = chain.count > 1 ? Array(chain.dropFirst()) : nil
        return snapshot
    }

    /// Agent keys resolve exactly only after a verification probe; the
    /// credential resolver itself is synchronous.
    private static func resolveCredentials(_ snapshot: VPNSharedProfileSnapshot) async throws -> VPNResolvedConfig {
        let keyIDs = ([snapshot.auth.keyID] + snapshot.jumpChain.map(\.auth.keyID)).compactMap { $0 }
        await withTaskGroup(of: Void.self) { group in
            for keyID in keyIDs {
                group.addTask { await ExternalSSHAgentRegistry.shared.verifyAgent(forKeyID: keyID) }
            }
        }
        return try VPNCredentialResolver.resolve(snapshot: snapshot)
    }

    private static func isAgentKey(_ credential: VPNResolvedCredential?) -> Bool {
        if case .agentKey = credential { return true }
        return false
    }

    private static func usesAgentSigning(_ resolved: VPNResolvedConfig) -> Bool {
        ([resolved.credential, resolved.jumpCredential] + (resolved.extraJumpCredentials ?? [])).contains(where: isAgentKey)
    }

    /// Older hosts and sysexts read only the first jump host and would dial the target from it.
    private func requireMultiHopSupport(_ snapshot: VPNSharedProfileSnapshot) async throws {
        guard snapshot.extraJumpHosts?.isEmpty == false else { return }
        if await hostInfo()?.supportsMultiHopJump != true {
            throw VPNHostConnectionError.requestFailed("Update the rootshell VPN host and system extension before using multiple jump hosts.")
        }
    }

    /// Starts the serverless "Local Capture" tunnel.
    func startDirect(dnsServers: [String]) async throws {
        let snapshot = VPNDirectProfile.snapshot(dnsServers: dnsServers)
        let payload = try VPNCredentialResolver.encode(VPNResolvedConfig(snapshot: snapshot, credential: nil, jumpCredential: nil))
        let request = VPNStartRequest(
            profileID: VPNDirectProfile.id,
            transportType: VPNSharedTransportType.direct.rawValue,
            resolvedConfig: payload,
            captureConfig: captureConfigProvider?()
        )
        try await ensureHostRunning()
        try await requireCaptureSupport()
        let response = try await send(VPNControlRequest(command: .startVPN, payload: try JSONEncoder().encode(request)))
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "start failed")
        }
    }

    /// Relays a provider message (HTTP capture) to the sysext. nil when the
    /// tunnel isn't up or doesn't answer.
    func providerMessage(_ message: Data, timeoutSeconds: Int = 10) async -> Data? {
        guard let response = try? await send(VPNControlRequest(command: .providerMessage, payload: message), timeoutSeconds: timeoutSeconds),
              response.success else { return nil }
        return response.payload ?? Data()
    }

    /// Adds the capture CA to the login keychain as a trusted SSL root.
    /// Waits for the user to answer the macOS password prompt.
    func installCATrust(certificateDER: Data) async throws {
        try await ensureHostRunning()
        try await requireCaptureSupport()
        let response = try await send(VPNControlRequest(command: .installCATrust, payload: certificateDER), timeoutSeconds: 300)
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "Could not trust the certificate.")
        }
    }

    func removeCATrust(certificateDER: Data) async throws {
        try await ensureHostRunning()
        try await requireCaptureSupport()
        let response = try await send(VPNControlRequest(command: .removeCATrust, payload: certificateDER), timeoutSeconds: 300)
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "Could not remove the certificate.")
        }
    }

    private func requireCaptureSupport() async throws {
        if await hostInfo()?.supportsHTTPCapture != true {
            throw VPNHostConnectionError.requestFailed("Update the rootshell VPN host and system extension before using HTTP capture.")
        }
    }

    func stop() async throws {
        // A wedged host must not leave the user unable to disconnect (the
        // sysext keeps the tunnel up independently): recover the host and
        // retry once before surfacing an error.
        var response: VPNControlResponse
        do {
            response = try await send(VPNControlRequest(command: .stopVPN))
        } catch {
            logger.error("stop failed (\(error.localizedDescription, privacy: .public)); recovering host and retrying")
            try await ensureHostRunning()
            response = try await send(VPNControlRequest(command: .stopVPN))
        }
        if !response.success {
            throw VPNHostConnectionError.requestFailed(response.error ?? "stop failed")
        }
    }

    func status() async -> VPNTunnelStatusResponse? {
        do {
            let response = try await send(VPNControlRequest(command: .getStatus))
            guard let payload = response.payload else {
                logger.error("getStatus: response missing payload")
                return nil
            }
            return try JSONDecoder().decode(VPNTunnelStatusResponse.self, from: payload)
        } catch {
            logger.error("getStatus failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Socket I/O (explicitly off the main actor)

    // Dedicated background queue for the blocking unix-socket round trips. Using
    // an explicit queue (not Task.detached) guarantees the blocking read never
    // runs on the main actor — during the system-extension approval wait the host
    // doesn't reply for a while, and any main-actor hop there beachballs the UI.
    nonisolated private static let ioQueue = DispatchQueue(
        label: "com.rootshell.vpn.host-io", attributes: .concurrent
    )

    private func ping() async -> Bool {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: VPNHostConnection.ping()) }
        }
    }

    private func hostInfo() async -> VPNHostInfoResponse? {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: VPNHostConnection.hostInfo()) }
        }
    }

    private func send(_ request: VPNControlRequest, timeoutSeconds: Int = 10) async throws -> VPNControlResponse {
        try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do { continuation.resume(returning: try VPNHostConnection.send(request, timeoutSeconds: timeoutSeconds)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

#endif
