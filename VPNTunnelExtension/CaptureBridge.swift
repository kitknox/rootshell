//
//  CaptureBridge.swift
//  VPNTunnelExtension
//
//  Extension side of HTTP capture: resolves the spool directory and CA key,
//  feeds the Go engine, and answers `capture.*` provider messages. On macOS the
//  root system extension's container is unreadable by the app, so the app pulls
//  spool files through `list` / `read`.
//

import Foundation
import os.log
@preconcurrency import TsshKit

nonisolated enum CaptureBridge {
    static let logger = Logger(subsystem: "com.rootshell.vpntunnel", category: "Capture")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeSession = ""
    nonisolated(unsafe) private static var activeNonce = ""

    #if os(macOS)
    /// The sysext keeps its own copy (including the CA key) so capture resumes
    /// after the extension restarts without the host.
    private static var sysextConfigURL: URL? {
        CapturePaths.root()?.appendingPathComponent("engine-sysext.json")
    }
    #endif

    // MARK: - Start

    /// Capture config to embed in the Go start config, or nil when there is none.
    static func initialConfig(options: [String: NSObject]?) -> CaptureEngineConfig? {
        #if os(macOS)
        if let data = options?["captureConfig"] as? Data,
           let cfg = try? JSONDecoder().decode(CaptureEngineConfig.self, from: data) {
            persist(cfg)
            return resolve(cfg, freshSegment: true)
        }
        guard let url = sysextConfigURL, let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(CaptureEngineConfig.self, from: data) else { return nil }
        return resolve(cfg, freshSegment: true)
        #else
        guard let cfg = CapturePaths.readEngineConfig() else { return nil }
        return resolve(cfg, freshSegment: true)
        #endif
    }

    /// Adds the capture config as the Go config's "capture" object.
    static func attach(_ capture: CaptureEngineConfig?, to goConfigJSON: String) -> String {
        guard let capture,
              let captureData = try? JSONEncoder().encode(capture),
              let captureObject = try? JSONSerialization.jsonObject(with: captureData),
              let goData = goConfigJSON.data(using: .utf8),
              var go = (try? JSONSerialization.jsonObject(with: goData)) as? [String: Any] else {
            return goConfigJSON
        }
        go["capture"] = captureObject
        guard let merged = try? JSONSerialization.data(withJSONObject: go),
              let json = String(data: merged, encoding: .utf8) else { return goConfigJSON }
        return json
    }

    // MARK: - Resolution

    /// Fills in the spool directory, segment nonce, and (iOS) the CA key.
    static func resolve(_ input: CaptureEngineConfig, freshSegment: Bool) -> CaptureEngineConfig {
        var cfg = input
        #if !os(macOS)
        if let ca = CaptureCAKeychain.read() {
            cfg.caCertPEM = ca.certPEM
            cfg.caKeyPEM = ca.keyPEM
        }
        #endif
        guard cfg.enabled, CapturePaths.isValidSessionID(cfg.sessionID),
              let root = CapturePaths.sessionsRoot() else {
            cfg.enabled = false
            return cfg
        }
        let dir = root.appendingPathComponent(cfg.sessionID, isDirectory: true)
        do {
            try CapturePaths.ensureDirectory(dir)
        } catch {
            logger.error("capture spool unavailable: \(error.localizedDescription, privacy: .public)")
            cfg.enabled = false
            return cfg
        }
        cfg.spoolDir = dir.path
        cfg.segmentNonce = lock.withLock { () -> String in
            if freshSegment || activeSession != cfg.sessionID || activeNonce.isEmpty {
                activeSession = cfg.sessionID
                activeNonce = String(UUID().uuidString.prefix(8)).lowercased()
            }
            return activeNonce
        }
        return cfg
    }

    #if os(macOS)
    private static func persist(_ cfg: CaptureEngineConfig) {
        guard let root = CapturePaths.root(), let url = sysextConfigURL,
              let data = try? JSONEncoder().encode(cfg) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
    #endif

    // MARK: - Messages

    /// Handles a `capture.*` message. `wantsIPv6` is true when capture was just
    /// enabled, so the provider can route IPv6 through the tunnel too.
    static func handle(_ message: Data) -> (reply: Data?, wantsIPv6: Bool) {
        guard let (command, body) = CaptureMessage.decode(message) else {
            return (encodeReply(CaptureReply(ok: false, error: "malformed capture message")), false)
        }
        switch command {
        case .configure:
            guard let cfg = try? JSONDecoder().decode(CaptureEngineConfig.self, from: body) else {
                return (encodeReply(CaptureReply(ok: false, error: "bad capture config")), false)
            }
            #if os(macOS)
            persist(cfg)
            #endif
            let resolved = resolve(cfg, freshSegment: false)
            guard let data = try? JSONEncoder().encode(resolved), let json = String(data: data, encoding: .utf8) else {
                return (encodeReply(CaptureReply(ok: false, error: "encode failed")), false)
            }
            var error: NSError?
            let ok = VpntunnelCaptureConfigure(json, &error)
            return (encodeReply(CaptureReply(ok: ok, error: error?.localizedDescription)), ok && resolved.enabled)

        case .stop:
            #if os(macOS)
            if let url = sysextConfigURL, let data = try? Data(contentsOf: url),
               var cfg = try? JSONDecoder().decode(CaptureEngineConfig.self, from: data) {
                cfg.enabled = false
                persist(cfg)
            }
            #endif
            lock.withLock {
                activeSession = ""
                activeNonce = ""
            }
            return (Data(VpntunnelCaptureStop().utf8), false)

        case .status:
            return (Data(VpntunnelGetStatus().utf8), false)

        case .reset:
            let count = VpntunnelCaptureResetFlows()
            return (encodeReply(CaptureReply(ok: true, count: Int(count))), false)

        case .sessions:
            return (encode(sessionInfos()), false)

        case .list:
            guard let ref = try? JSONDecoder().decode(CaptureSessionRef.self, from: body) else {
                return (encode([CaptureFileInfo]()), false)
            }
            return (encode(fileInfos(session: ref.session)), false)

        case .read:
            guard let req = try? JSONDecoder().decode(CaptureReadRequest.self, from: body) else {
                return (Data(), false)
            }
            return (read(req), false)

        case .delete:
            guard let ref = try? JSONDecoder().decode(CaptureSessionRef.self, from: body),
                  CapturePaths.isValidSessionID(ref.session),
                  let root = CapturePaths.sessionsRoot() else {
                return (encodeReply(CaptureReply(ok: false, error: "bad session")), false)
            }
            let isActive = lock.withLock { activeSession == ref.session }
            if isActive {
                return (encodeReply(CaptureReply(ok: false, error: "session is recording")), false)
            }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(ref.session, isDirectory: true))
            return (encodeReply(CaptureReply(ok: true)), false)
        }
    }

    private static func sessionInfos() -> [CaptureFileInfo] {
        guard let root = CapturePaths.sessionsRoot(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter(CapturePaths.isValidSessionID).map { CaptureFileInfo(path: $0, size: 0) }
    }

    private static func fileInfos(session: String) -> [CaptureFileInfo] {
        guard CapturePaths.isValidSessionID(session), let root = CapturePaths.sessionsRoot() else { return [] }
        let dir = root.appendingPathComponent(session, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return [] }
        var out: [CaptureFileInfo] = []
        let prefix = dir.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            out.append(CaptureFileInfo(path: String(path.dropFirst(prefix.count)), size: Int64(values.fileSize ?? 0)))
        }
        return out
    }

    private static func read(_ req: CaptureReadRequest) -> Data {
        guard CapturePaths.isValidSessionID(req.session),
              CapturePaths.isValidRelativePath(req.path),
              let root = CapturePaths.sessionsRoot() else { return Data() }
        let url = root.appendingPathComponent(req.session, isDirectory: true).appendingPathComponent(req.path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, req.offset)))
            return try handle.read(upToCount: min(max(0, req.max), CapturePaths.readChunkLimit)) ?? Data()
        } catch {
            return Data()
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func encodeReply(_ reply: CaptureReply) -> Data? {
        encode(reply)
    }
}
