import Foundation

/// A verified local attachment, never a shell command to replay. Shared with
/// the helper so validation and launch use the same allowlist and wire format.
public nonisolated struct LocalMultiplexerAttachment: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var kind: String
    public var controlMode: Bool
    public var executable: String
    public var socketPath: String
    public var socketDevice: UInt64
    public var socketInode: UInt64
    public var serverPID: Int32
    public var serverStartedAt: UInt64
    public var sessionName: String
    public var sessionID: Int?
    public var sessionCreatedAt: UInt64?
    public var environment: [String: String]

    public var isTmuxControl: Bool { kind == "tmux" && controlMode }
    public var isHerdrControl: Bool { kind == "herdr" && controlMode }

    public func matchesIdentity(of other: Self) -> Bool {
        kind == other.kind && controlMode == other.controlMode
            && socketPath == other.socketPath && socketDevice == other.socketDevice && socketInode == other.socketInode
            && serverPID == other.serverPID && serverStartedAt == other.serverStartedAt
            && sessionID == other.sessionID && sessionCreatedAt == other.sessionCreatedAt
            && (kind == "tmux" || sessionName == other.sessionName)
    }

    public static let environmentKeys: Set<String> = [
        "ZELLIJ_SOCKET_DIR", "ZELLIJ_CONFIG_DIR", "ZELLIJ_CONFIG_FILE",
        "HERDR_CONFIG_PATH", "HERDR_SOCKET_PATH", "HERDR_SESSION",
        "ZMX_DIR", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR"
    ]

    public var isValid: Bool {
        version == 1 && ["tmux", "zellij", "herdr", "zmx"].contains(kind)
            && (!controlMode || kind == "tmux" || kind == "herdr")
            && executable.hasPrefix("/") && socketPath.hasPrefix("/")
            && (executable as NSString).lastPathComponent == kind
            && socketInode > 0 && serverPID > 0 && serverStartedAt > 0
            && !sessionName.isEmpty && sessionName.utf8.count <= 1024
            && (kind != "tmux" || (sessionID.map { $0 >= 0 } == true && sessionCreatedAt != nil))
            && Set(environment.keys).isSubset(of: Self.environmentKeys)
            && ([executable, socketPath, sessionName] + Array(environment.values)).allSatisfy {
                $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// No create flags, shell aliases, or inherited inside-multiplexer identity.
    public var attachArguments: [String] {
        switch kind {
        case "tmux":
            return ["-S", socketPath] + (controlMode ? ["-CC"] : [])
                + ["attach-session", "-t", "$\(sessionID ?? -1)"]
        // herdr's session subcommand rejects `--` and overrides custom socket
        // selection. Its normal entry point honors the verified API socket.
        case "herdr": return isHerdrControl ? ["control"] : []
        case "zmx": return ["attach", sessionName]
        default: return ["attach", "--", sessionName]
        }
    }

    public var launchEnvironment: [String: String] {
        var result = environment
        switch kind {
        case "zmx":
            result["ZMX_DIR"] = (socketPath as NSString).deletingLastPathComponent
        case "herdr":
            result["HERDR_SESSION"] = sessionName
            if isHerdrControl {
                result["HERDR_SOCKET_PATH"] = socketPath
            } else if result["HERDR_SOCKET_PATH"] == nil {
                result["HERDR_SOCKET_PATH"] = ((socketPath as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent("herdr.sock")
            }
        default: break
        }
        return result
    }

    /// One trusted startup command, run by the helper before the login shell.
    /// All variable data are single-quoted arguments, not executable syntax.
    public var attachCommand: String {
        command(arguments: attachArguments)
    }

    /// Native herdr owns an auxiliary connection; its gateway PTY stays a shell.
    public var ptyRecoveryCommand: String? { isHerdrControl ? nil : attachCommand }

    public func command(arguments: [String]) -> String {
        let cleared = ["TMUX", "TMUX_PANE", "ZELLIJ", "ZELLIJ_SESSION_NAME", "HERDR_ENV", "ZMX_SESSION", "ZMX_SESSION_PREFIX"]
        return (["/usr/bin/env"] + cleared.flatMap { ["-u", $0] }
            + launchEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            + [executable] + arguments).map(Self.quote).joined(separator: " ")
    }
}

/// Explicit controller intent, keyed by an owned gateway shell session in the
/// census request. A pinned attachment selects its namespace, never a command
/// recovered from saved shell history.
nonisolated struct LocalHerdrControlTarget: Codable, Sendable {
    var sessionName: String?
    var attachment: LocalMultiplexerAttachment? = nil

    var isValid: Bool {
        if let attachment { return attachment.isValid && attachment.isHerdrControl }
        return sessionName.map {
            !$0.isEmpty && $0.utf8.count <= 1024
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        } ?? true
    }

    var statusCommand: String {
        if let attachment { return attachment.command(arguments: ["status", "--json"]) }
        let session = sessionName.map { " --session " + LoginShellCommand.singleQuoted($0) } ?? ""
        return LoginShellCommand.runInPOSIXShell(LoginShellCommand.pathPrefix + "exec herdr\(session) status --json")
    }
}

/// A bad/newer optional recovery record must not discard the entire window.
@propertyWrapper
nonisolated struct LossyLocalMultiplexerAttachment: Codable, Equatable, Sendable {
    var wrappedValue: LocalMultiplexerAttachment?
    init(wrappedValue: LocalMultiplexerAttachment? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let value = try? LocalMultiplexerAttachment(from: decoder)
        wrappedValue = value?.isValid == true ? value : nil
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue?.isValid == true ? wrappedValue : nil)
    }
}

// Synthesized `init(from:)` of the types holding this wrapper is nonisolated.
nonisolated extension KeyedDecodingContainer {
    func decode(_ type: LossyLocalMultiplexerAttachment.Type, forKey key: Key) throws -> LossyLocalMultiplexerAttachment {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
}
