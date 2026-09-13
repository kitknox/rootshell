import Foundation

/// Runs on the helper's connection queue. The PTY, connected socket, and server
/// process must all agree; display titles and argv session names are not proof.
enum LocalMultiplexerRecovery {
    typealias Record = [String: Any]

    final class ProbeCache {
        private struct Key: Hashable {
            let executable: String
            let arguments: [String]
            let environment: [String]
        }
        private var replies: [Key: String?] = [:]

        func run(_ executable: String, _ arguments: [String], environment: [String: String], deadline: Date) -> String? {
            let key = Key(executable: executable, arguments: arguments,
                          environment: environment.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] })
            if let reply = replies[key] { return reply }
            let reply = LocalMultiplexerRecovery.run(executable, arguments, environment: environment, deadline: deadline)
            replies.updateValue(reply, forKey: key)
            return reply
        }
    }

    static func processes() -> [Record] {
        ProcessSpawner.localMultiplexerProcesses(Array(LocalMultiplexerAttachment.environmentKeys))
    }

    static func number(_ record: Record, _ key: String) -> UInt64 {
        (record[key] as? NSNumber)?.uint64Value ?? 0
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func paths(_ record: Record, _ key: String) -> Set<String> {
        Set((record[key] as? [String] ?? []).map { canonical($0) })
    }

    static func socketIdentity(_ path: String) -> (device: UInt64, inode: UInt64)? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }

    static func inspect(shellPID: Int32, pty: PTYPair, records: [Record], deadline: Date,
                        cache: ProbeCache = ProbeCache()) -> LocalMultiplexerAttachment? {
        // PROC_PIDTBSDINFO can return EPERM for the privileged login parent.
        // The helper already owns this PTY and knows the PID it spawned; use
        // the slave device for terminal identity, and stop ancestry traversal
        // at that known PID without requiring a readable record for it.
        var terminal = stat()
        guard stat(pty.slavePath, &terminal) == 0, terminal.st_mode & S_IFMT == S_IFCHR else { return nil }
        let terminalDevice = UInt64(UInt32(bitPattern: terminal.st_rdev))
        let foreground = tcgetpgrp(pty.masterFD)
        guard shellPID > 0, foreground > 0 else { return nil }
        let byPID = Dictionary(records.map { (number($0, "pid"), $0) }, uniquingKeysWith: { a, _ in a })
        func belongsToShell(_ process: Record) -> Bool {
            var pid = number(process, "pid")
            var visited: Set<UInt64> = []
            while pid > 1, visited.insert(pid).inserted {
                if pid == UInt64(shellPID) { return true }
                guard let parent = byPID[pid] else { return false }
                pid = number(parent, "ppid")
            }
            return false
        }
        let clients = records.filter {
            number($0, "tty") == terminalDevice
                && number($0, "pgid") == UInt64(foreground)
                && $0["sockets"] != nil && belongsToShell($0)
                && paths($0, "listeners").isEmpty
        }
        var attachments: [LocalMultiplexerAttachment] = []
        for client in clients {
            guard Date() < deadline, let executable = client["executable"] as? String else { continue }
            let kind = (executable as NSString).lastPathComponent
            for socket in paths(client, "sockets") {
                let servers = records.filter {
                    ($0["executable"] as? String).map { ($0 as NSString).lastPathComponent } == kind
                        && number($0, "pid") != number(client, "pid")
                        && paths($0, "listeners").contains(socket)
                }
                guard servers.count == 1, let server = servers.first,
                      let identity = socketIdentity(socket) else { continue }
                var attachment = LocalMultiplexerAttachment(
                    kind: kind, controlMode: false, executable: executable, socketPath: socket,
                    socketDevice: identity.device, socketInode: identity.inode,
                    serverPID: Int32(number(server, "pid")), serverStartedAt: number(server, "startedAt"),
                    sessionName: (socket as NSString).lastPathComponent, environment: client["environment"] as? [String: String] ?? [:])
                if kind == "tmux" {
                    guard let output = cache.run(executable, ["-S", socket, "list-clients", "-F",
                        "#{client_pid}\t#{session_id}\t#{session_created}\t#{client_control_mode}\t#{q:session_name}"],
                        environment: [:], deadline: deadline),
                          let fields = tmuxRows(output).first(where: { $0.first == String(number(client, "pid")) }),
                          fields.count == 5, fields[1].hasPrefix("$"),
                          let id = Int(fields[1].dropFirst()), let created = UInt64(fields[2]) else { continue }
                    attachment.sessionID = id
                    attachment.sessionCreatedAt = created
                    attachment.controlMode = fields[3] == "1"
                    attachment.sessionName = fields[4]
                } else if kind == "herdr" {
                    guard (socket as NSString).lastPathComponent == "herdr-client.sock" else { continue }
                    let directory = (socket as NSString).deletingLastPathComponent as NSString
                    let parent = directory.deletingLastPathComponent as NSString
                    attachment.sessionName = parent.lastPathComponent == "sessions" ? directory.lastPathComponent : "default"
                    // Preserve a custom API socket only when this same server
                    // owns it; otherwise verify the usual sibling API socket.
                    let apiSocket = attachment.environment["HERDR_SOCKET_PATH"]
                        ?? directory.appendingPathComponent("herdr.sock")
                    guard paths(server, "listeners").contains(canonical(apiSocket)) else { continue }
                    attachment.environment["HERDR_SOCKET_PATH"] = canonical(apiSocket)
                }
                guard attachment.isValid, namespaceIsLive(attachment, deadline: deadline, cache: cache) else { continue }
                attachments.append(attachment)
            }
        }
        guard let first = attachments.first, attachments.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    static func isAvailable(_ attachment: LocalMultiplexerAttachment) -> Bool {
        guard hasOriginalServer(attachment, records: processes()) else { return false }
        let deadline = Date().addingTimeInterval(6)
        if attachment.kind == "tmux" {
            guard let output = run(attachment.executable,
                ["-S", attachment.socketPath, "list-sessions", "-F", "#{session_id}\t#{session_created}"],
                environment: attachment.launchEnvironment, deadline: deadline) else { return false }
            return tmuxRows(output).contains { $0 == ["$\(attachment.sessionID ?? -1)", String(attachment.sessionCreatedAt ?? 0)] }
        }
        return namespaceIsLive(attachment, deadline: deadline)
    }

    static func hasOriginalServer(_ attachment: LocalMultiplexerAttachment, records: [Record]) -> Bool {
        guard attachment.isValid, FileManager.default.isExecutableFile(atPath: attachment.executable),
              let socket = socketIdentity(attachment.socketPath),
              socket.device == attachment.socketDevice, socket.inode == attachment.socketInode,
              records.contains(where: {
                  number($0, "pid") == UInt64(attachment.serverPID)
                    && number($0, "startedAt") == attachment.serverStartedAt
                    && ($0["executable"] as? String).map { ($0 as NSString).lastPathComponent } == attachment.kind
                    && paths($0, "listeners").contains(canonical(attachment.socketPath))
              }) else { return false }
        return true
    }

    struct HerdrStatus: Decodable {
        struct Client: Decodable { let binary: String; let session: String? }
        struct Server: Decodable { let running: Bool; let socket: String; let session: String? }
        let client: Client
        let server: Server

        static func parse(_ output: String) -> Self? {
            // A login profile may print a greeting before the CLI's JSON line.
            output.split(separator: "\n").reversed().compactMap {
                try? JSONDecoder().decode(Self.self, from: Data($0.utf8))
            }.first
        }
    }

    /// Native herdr uses pipes/auxiliary PTYs instead of a foreground client
    /// on the gateway PTY. The caller supplies controller intent; the helper
    /// verifies the resolved API socket against its same-user server census.
    static func inspectHerdrControl(_ target: LocalHerdrControlTarget, records: [Record], deadline: Date,
                                    cache: ProbeCache = ProbeCache()) -> LocalMultiplexerAttachment? {
        guard target.isValid else { return nil }
        let output: String?
        if let attachment = target.attachment {
            output = cache.run(attachment.executable, ["status", "--json"],
                               environment: attachment.launchEnvironment, deadline: deadline)
        } else {
            output = cache.run("/bin/zsh", ["-lc", "exec " + target.statusCommand], environment: [:], deadline: deadline)
        }
        guard let output else { return nil }
        return herdrControlAttachment(statusOutput: output, records: records)
    }

    static func herdrControlAttachment(statusOutput: String, records: [Record]) -> LocalMultiplexerAttachment? {
        guard let status = HerdrStatus.parse(statusOutput), status.server.running,
              status.server.socket.hasPrefix("/"), status.client.binary.hasPrefix("/"),
              (status.client.binary as NSString).lastPathComponent == "herdr",
              FileManager.default.isExecutableFile(atPath: status.client.binary) else { return nil }
        let socket = canonical(status.server.socket)
        let servers = records.filter {
            ($0["executable"] as? String).map { ($0 as NSString).lastPathComponent } == "herdr"
                && paths($0, "listeners").contains(socket)
        }
        guard servers.count == 1, let server = servers.first,
              let identity = socketIdentity(socket),
              let pid = Int32(exactly: number(server, "pid")) else { return nil }
        let name = status.server.session ?? status.client.session ?? "default"
        var environment = server["environment"] as? [String: String] ?? [:]
        environment["HERDR_SOCKET_PATH"] = socket
        environment["HERDR_SESSION"] = name
        let attachment = LocalMultiplexerAttachment(
            kind: "herdr", controlMode: true, executable: status.client.binary, socketPath: socket,
            socketDevice: identity.device, socketInode: identity.inode,
            serverPID: pid, serverStartedAt: number(server, "startedAt"), sessionName: name,
            environment: environment)
        return attachment.isValid ? attachment : nil
    }

    /// Verifies the CLI namespace before an attach that can create/resurrect.
    /// The socket/server identity check above excludes a replacement session.
    static func namespaceIsLive(_ attachment: LocalMultiplexerAttachment, deadline: Date,
                                cache: ProbeCache = ProbeCache()) -> Bool {
        switch attachment.kind {
        case "tmux": return true
        case "zmx":
            guard let output = cache.run(attachment.executable, ["list", "--short"], environment: attachment.launchEnvironment, deadline: deadline) else { return false }
            return output.split(separator: "\n").contains(Substring(attachment.sessionName))
        case "zellij":
            guard let output = cache.run(attachment.executable, ["list-sessions", "--no-formatting", "--short"], environment: attachment.launchEnvironment, deadline: deadline) else { return false }
            // A live server owning this exact socket was already established.
            // Short output checks CLI namespace without parsing localized prose.
            return output.split(separator: "\n").contains(Substring(attachment.sessionName))
        case "herdr":
            if attachment.isHerdrControl {
                guard let output = cache.run(attachment.executable, ["status", "--json"],
                                            environment: attachment.launchEnvironment, deadline: deadline),
                      let status = HerdrStatus.parse(output) else { return false }
                return status.server.running && canonical(status.server.socket) == canonical(attachment.socketPath)
                    && (status.server.session ?? status.client.session ?? "default") == attachment.sessionName
            }
            guard let output = cache.run(attachment.executable, ["session", "list", "--json"], environment: attachment.launchEnvironment, deadline: deadline),
                  let data = output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return false }
            let rows = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["sessions"] as? [[String: Any]]) ?? []
            guard let apiSocket = attachment.launchEnvironment["HERDR_SOCKET_PATH"] else { return false }
            return rows.contains {
                ($0["name"] as? String) == attachment.sessionName && ($0["running"] as? Bool) == true
                    && ($0["socket_path"] as? String).map({ path in canonical(path) }) == canonical(apiSocket)
            }
        default: return false
        }
    }

    static func tmuxRows(_ output: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", escaped = false
        for c in output {
            if escaped { field.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\t" { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if escaped { return [] }
        if !row.isEmpty || !field.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// Direct exec avoids shell startup scripts changing namespaces or emitting
    /// output. Bound both time and bytes; callers share one census deadline.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String], deadline: Date) -> String? {
        guard Date() < deadline else { return nil }
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = EnvironmentBuilder().build()
            .merging(environment) { _, new in new }
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        pipe.fileHandleForWriting.closeFile()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { pipe.fileHandleForReading.closeFile() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        var failed = false
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            if count == 0, !task.isRunning { break }
            if count < 0 && errno != EAGAIN && errno != EINTR { failed = true; break }
            if Date() >= deadline || data.count > 65536 { failed = true; break }
            if count <= 0 { usleep(10_000) }
        }
        if failed, task.isRunning { kill(task.processIdentifier, SIGKILL) }
        task.waitUntilExit()
        guard !failed, task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
