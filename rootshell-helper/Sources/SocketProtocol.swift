import Foundation

/// Protocol for communication between rootshell (Catalyst) and rootshell-helper
/// over Unix domain sockets in the shared App Group container.
///
/// This replaces XPC communication which is not available on Mac Catalyst.

// MARK: - Command Types

enum SocketCommand: String, Codable {
    case createShell
    case resizeShell
    case killShell
    case ping
    case executeCommand
}

// MARK: - Request/Response Messages

struct SocketRequest: Codable {
    let command: SocketCommand
    let payload: Data?

    init(command: SocketCommand, payload: Data? = nil) {
        self.command = command
        self.payload = payload
    }
}

struct SocketResponse: Codable {
    let success: Bool
    let payload: Data?
    let error: String?
    let helperPID: pid_t?

    init(success: Bool, payload: Data? = nil, error: String? = nil, helperPID: pid_t? = nil) {
        self.success = success
        self.payload = payload
        self.error = error
        self.helperPID = helperPID
    }
}

// MARK: - Command Payloads

struct CreateShellRequest: Codable {
    let rows: UInt16
    let cols: UInt16
    let cwd: String?
    let shell: String?
    let resourcesDir: String?
    let enableShellIntegration: Bool
    let sshAuthSock: String?
    /// Short version for TERM_PROGRAM_VERSION. Optional so an older app
    /// (or an older helper) still decodes the request.
    let appVersion: String?
    /// Short version plus build for LC_TERMINAL_VERSION.
    let appVersionWithBuild: String?
    /// TERM for the spawned shell, chosen in the app's settings. Optional so an
    /// older app still decodes here; nil keeps the helper's own default.
    let termType: String?
    /// Stable TerminalView UUID exported as LC_ROOTSHELL_PANE. Optional for
    /// compatibility with older app builds.
    let paneToken: String?
}

struct CreateShellResponse: Codable {
    let sessionID: UUID
    let socketPath: String
}

struct ResizeShellRequest: Codable {
    let sessionID: UUID
    let rows: UInt16
    let cols: UInt16
}

struct KillShellRequest: Codable {
    let sessionID: UUID
}

// MARK: - Execute Command (Non-Interactive)

struct ExecuteCommandRequest: Codable {
    let command: String
    let workingDirectory: String?
    let timeout: TimeInterval?
    let environment: [String: String]?
}

/// Streaming output chunk sent during command execution
struct ExecuteOutputChunk: Codable {
    let data: Data      // UTF-8 encoded output chunk
    let isStderr: Bool  // true if from stderr, false for stdout
}

/// Final response after command completes
struct ExecuteComplete: Codable {
    let exitCode: Int32
    let timedOut: Bool
    let duration: TimeInterval
}

// MARK: - Wire Protocol

/// Wire protocol for socket messages:
/// 1. 4 bytes: message length (UInt32, network byte order)
/// 2. N bytes: JSON-encoded SocketRequest or SocketResponse
struct SocketMessage {
    static func encode<T: Encodable>(_ message: T) throws -> Data {
        let jsonData = try JSONEncoder().encode(message)
        var length = UInt32(jsonData.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(jsonData)
        return data
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        guard data.count >= 4 else {
            throw SocketProtocolError.invalidMessage
        }

        let bytes = [UInt8](data.prefix(4))
        let length =
            (UInt32(bytes[0]) << 24) |
            (UInt32(bytes[1]) << 16) |
            (UInt32(bytes[2]) << 8) |
            UInt32(bytes[3])

        guard data.count >= 4 + Int(length) else {
            throw SocketProtocolError.incompleteMessage
        }

        let jsonData = data.subdata(in: 4..<(4 + Int(length)))
        return try JSONDecoder().decode(T.self, from: jsonData)
    }

    /// Read a complete message from a file descriptor
    static func read(from fd: Int32) throws -> Data {
        // Read 4-byte length prefix
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let lengthRead = Darwin.read(fd, &lengthBytes, 4)
        guard lengthRead == 4 else {
            throw SocketProtocolError.connectionClosed
        }

        let length =
            (UInt32(lengthBytes[0]) << 24) |
            (UInt32(lengthBytes[1]) << 16) |
            (UInt32(lengthBytes[2]) << 8) |
            UInt32(lengthBytes[3])
        guard length > 0 && length < 1024 * 1024 else { // Max 1MB message
            throw SocketProtocolError.invalidMessage
        }

        // Read message body
        var messageBytes = [UInt8](repeating: 0, count: Int(length))
        var totalRead = 0
        while totalRead < Int(length) {
            let bytesRead = messageBytes.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress! + totalRead, Int(length) - totalRead)
            }
            guard bytesRead > 0 else {
                throw SocketProtocolError.connectionClosed
            }
            totalRead += bytesRead
        }

        // Return complete message (length prefix + body)
        var result = Data(lengthBytes)
        result.append(Data(messageBytes))
        return result
    }

    /// Write a complete message to a file descriptor
    static func write(_ data: Data, to fd: Int32) throws {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var remaining = data.count
        var offset = 0

        while remaining > 0 {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress! + offset, remaining)
            }

            guard written > 0 else {
                throw SocketProtocolError.writeFailed
            }

            remaining -= written
            offset += written
        }
    }
}

// MARK: - Errors

enum SocketProtocolError: Error, LocalizedError {
    case invalidMessage
    case incompleteMessage
    case connectionClosed
    case writeFailed
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidMessage: return "Invalid socket message format"
        case .incompleteMessage: return "Incomplete socket message"
        case .connectionClosed: return "Socket connection closed"
        case .writeFailed: return "Failed to write to socket"
        case .encodingFailed: return "Failed to encode message"
        case .decodingFailed: return "Failed to decode message"
        }
    }
}

// MARK: - App Group Helper

nonisolated struct AppGroupHelper {
    /// Read from our own Info.plist so it tracks the org identifier this copy
    /// was built with. `AppIdentifiers` can't be shared here -- the helper has
    /// its own source tree and doesn't compile the app's `rootshell` folder.
    static let groupIdentifier: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RootshellDefaultAppGroup") as? String,
              !value.isEmpty else { return "group.com.kk2.ghostty" }
        return value
    }()

    /// Set from --app-group argv so the spawning app stays authoritative.
    static var overrideGroupIdentifier: String?

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: overrideGroupIdentifier ?? groupIdentifier
        )
    }

    static var commandSocketPath: String? {
        containerURL?.appendingPathComponent("commands.sock").path
    }

    static func sessionSocketPath(for sessionID: UUID) -> String? {
        // First 8 UUID hex chars only: the full UUID pushes sun_path past its
        // 104-byte limit for usernames of 9+ chars. Sessions stay keyed by
        // full UUID; the client binds the returned path verbatim.
        containerURL?.appendingPathComponent("\(sessionID.uuidString.prefix(8)).sock").path
    }
}
