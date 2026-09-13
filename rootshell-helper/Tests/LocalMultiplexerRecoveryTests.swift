import XCTest

final class LocalMultiplexerRecoveryTests: XCTestCase {
    private struct SavedLeaf: Codable {
        var title: String
        @LossyLocalMultiplexerAttachment var attachment: LocalMultiplexerAttachment? = nil
    }

    private func fixture(kind: String = "tmux") -> LocalMultiplexerAttachment {
        LocalMultiplexerAttachment(
            kind: kind, controlMode: kind == "tmux", executable: "/opt/homebrew/bin/\(kind)",
            socketPath: "/tmp/recovery socket", socketDevice: 1, socketInode: 2,
            serverPID: 123, serverStartedAt: 456, sessionName: "work ' $HOME `echo unsafe`",
            sessionID: kind == "tmux" ? 7 : nil, sessionCreatedAt: kind == "tmux" ? 1234 : nil,
            environment: [:])
    }

    func testOldAndUnknownRecordsDoNotDiscardLeaf() throws {
        let old = try JSONDecoder().decode(SavedLeaf.self, from: Data(#"{"title":"kept"}"#.utf8))
        XCTAssertEqual(old.title, "kept")
        XCTAssertNil(old.attachment)
        for bad in [#"{"version":999}"#, #""wrong shape""#, "42", "null"] {
            let leaf = try JSONDecoder().decode(SavedLeaf.self, from: Data("{\"title\":\"kept\",\"attachment\":\(bad)}".utf8))
            XCTAssertEqual(leaf.title, "kept")
            XCTAssertNil(leaf.attachment)
        }
        var future = fixture()
        future.version = 2
        let data = try JSONEncoder().encode(SavedLeaf(title: "kept", attachment: future))
        XCTAssertNil(try JSONDecoder().decode(SavedLeaf.self, from: data).attachment)
    }

    func testPendingAttachmentRoundTrips() throws {
        for kind in ["tmux", "zellij", "herdr", "zmx"] {
            let leaf = SavedLeaf(title: "pending", attachment: fixture(kind: kind))
            let encoded = try JSONEncoder().encode(leaf)
            let decoded = try JSONDecoder().decode(SavedLeaf.self, from: encoded)
            XCTAssertEqual(decoded.attachment, leaf.attachment)
        }
    }

    func testRejectsIncompleteIdentityAndUnapprovedEnvironment() {
        var value = fixture()
        value.sessionCreatedAt = nil
        XCTAssertFalse(value.isValid)
        value = fixture()
        value.environment["DYLD_INSERT_LIBRARIES"] = "/tmp/library"
        XCTAssertFalse(value.isValid)
        value = fixture()
        value.socketPath = "relative/socket"
        XCTAssertFalse(value.isValid)
        value = fixture()
        value.sessionName = "first\nsecond"
        XCTAssertFalse(value.isValid)
    }

    func testAttachUsesExactTmuxIDAndClearsNestedIdentity() {
        let value = fixture()
        XCTAssertEqual(value.attachArguments, ["-S", value.socketPath, "-CC", "attach-session", "-t", "$7"])
        XCTAssertFalse(value.attachCommand.contains("new-session"))
        XCTAssertTrue(value.attachCommand.contains("'-u' 'TMUX'"))
        let zmx = fixture(kind: "zmx")
        XCTAssertEqual(zmx.attachArguments, ["attach", zmx.sessionName])
        XCTAssertEqual(zmx.launchEnvironment["ZMX_DIR"], "/tmp")
        XCTAssertTrue(zmx.attachCommand.contains("'-u' 'ZMX_SESSION'"))
        XCTAssertTrue(zmx.attachCommand.contains("'-u' 'ZMX_SESSION_PREFIX'"))
    }

    func testQuotedNamesRemainLiteral() {
        let name = fixture().sessionName
        let output = LocalMultiplexerRecovery.run("/bin/sh", ["-c", "printf '%s' " + LocalMultiplexerAttachment.quote(name)],
            environment: [:], deadline: Date().addingTimeInterval(3))
        XCTAssertEqual(output, name)
    }

    func testHerdrUsesVerifiedSocketWithoutSessionCLIOverride() {
        var value = fixture(kind: "herdr")
        value.sessionName = "default"
        value.socketPath = "/tmp/custom/herdr-client.sock"
        value.environment["HERDR_SOCKET_PATH"] = "/tmp/custom/herdr.sock"
        XCTAssertEqual(value.attachArguments, [])
        XCTAssertEqual(value.launchEnvironment["HERDR_SESSION"], "default")
        XCTAssertEqual(value.launchEnvironment["HERDR_SOCKET_PATH"], "/tmp/custom/herdr.sock")
        XCTAssertTrue(value.attachCommand.contains("'HERDR_SOCKET_PATH=/tmp/custom/herdr.sock'"))
    }

    func testHerdrControlPersistsAndLeavesGatewayPTYInShell() throws {
        var value = fixture(kind: "herdr")
        value.controlMode = true
        value.socketPath = "/tmp/custom api.sock"
        value.environment["HERDR_SOCKET_PATH"] = "/tmp/wrong.sock"
        XCTAssertTrue(value.isValid)
        XCTAssertTrue(value.isHerdrControl)
        XCTAssertFalse(value.isTmuxControl)
        XCTAssertNil(value.ptyRecoveryCommand)
        XCTAssertEqual(value.launchEnvironment["HERDR_SOCKET_PATH"], value.socketPath)
        XCTAssertEqual(value.attachArguments, ["control"])
        let saved = SavedLeaf(title: "native gateway", attachment: value)
        XCTAssertEqual(try JSONDecoder().decode(SavedLeaf.self, from: JSONEncoder().encode(saved)).attachment, value)
        for args in [["control"], ["remote-client-bridge"], ["api", "snapshot"], ["terminal", "attach", "pane-1", "--takeover"]] {
            XCTAssertTrue(value.command(arguments: args).contains("'HERDR_SOCKET_PATH=/tmp/custom api.sock'"))
            XCTAssertFalse(value.command(arguments: args).contains("--session"))
        }
        var unsupported = fixture(kind: "zellij")
        unsupported.controlMode = true
        XCTAssertFalse(unsupported.isValid)
    }

    func testRecoveryIdentityDistinguishesControlKindsAndReplacementServers() {
        var original = fixture(kind: "herdr")
        original.controlMode = true
        XCTAssertTrue(original.matchesIdentity(of: original))
        var changed = original
        changed.serverStartedAt += 1
        XCTAssertFalse(changed.matchesIdentity(of: original))
        changed = original
        changed.socketInode += 1
        XCTAssertFalse(changed.matchesIdentity(of: original))
        changed = original
        changed.sessionName = "another"
        XCTAssertFalse(changed.matchesIdentity(of: original))
        changed = original
        changed.controlMode = false
        XCTAssertFalse(changed.matchesIdentity(of: original))
        var renamedTmux = fixture()
        renamedTmux.sessionName = "renamed"
        XCTAssertTrue(renamedTmux.matchesIdentity(of: fixture()))
    }

    func testHerdrTargetAndStatusValidation() throws {
        XCTAssertTrue(LocalHerdrControlTarget(sessionName: nil).isValid)
        XCTAssertFalse(LocalHerdrControlTarget(sessionName: "bad\nname").isValid)
        XCTAssertFalse(LocalHerdrControlTarget(sessionName: "default", attachment: fixture()).isValid)
        let oldRequest = try JSONDecoder().decode(LocalHerdrControlTarget.self, from: Data(#"{"sessionName":null}"#.utf8))
        XCTAssertNil(oldRequest.attachment)
        let output = #"{"client":{"binary":"/tmp/herdr","session":null},"server":{"running":true,"socket":"/tmp/custom.sock","session":null}}"#
        XCTAssertEqual(LocalMultiplexerRecovery.HerdrStatus.parse("login greeting\n" + output)?.server.socket, "/tmp/custom.sock")
        XCTAssertNil(LocalMultiplexerRecovery.HerdrStatus.parse("not JSON"))
        XCTAssertNil(LocalMultiplexerRecovery.herdrControlAttachment(statusOutput: output, records: []))
    }

    /// No foreground multiplexer client or gateway PTY is involved. All
    /// processes and sockets belong to this test's private config directory.
    func testLiveHerdrControlIdentityWithoutForegroundPTY() throws {
        let candidates = [FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/herdr",
                          "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("herdr is not installed")
        }
        let directory = "/tmp/rs-herdr-recovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = directory + "/config.toml", socket = directory + "/custom.sock"
        try Data().write(to: URL(fileURLWithPath: config))
        let environment = ["HERDR_CONFIG_PATH": config, "HERDR_SOCKET_PATH": socket, "HERDR_SESSION": "recovery"]
        let server = Process()
        server.executableURL = URL(fileURLWithPath: executable)
        server.arguments = ["server"]
        server.environment = EnvironmentBuilder().build().merging(environment) { _, new in new }
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
            server.waitUntilExit()
            try? FileManager.default.removeItem(atPath: directory)
        }
        let deadline = Date().addingTimeInterval(6)
        var attachment: LocalMultiplexerAttachment?
        while Date() < deadline, server.isRunning {
            if let status = LocalMultiplexerRecovery.run(executable, ["status", "--json"], environment: environment, deadline: deadline) {
                attachment = LocalMultiplexerRecovery.herdrControlAttachment(statusOutput: status, records: LocalMultiplexerRecovery.processes())
                if attachment != nil { break }
            }
            usleep(50_000)
        }
        let saved = try XCTUnwrap(attachment, "No verified herdr API server appeared")
        XCTAssertTrue(saved.isHerdrControl)
        XCTAssertNil(saved.ptyRecoveryCommand)
        XCTAssertEqual(saved.socketPath, LocalMultiplexerRecovery.canonical(socket))
        XCTAssertEqual(saved.serverPID, server.processIdentifier)
        XCTAssertEqual(saved.sessionName, "recovery")
        XCTAssertTrue(LocalMultiplexerRecovery.isAvailable(saved))
        let target = LocalHerdrControlTarget(sessionName: "ignored", attachment: saved)
        let observed = LocalMultiplexerRecovery.inspectHerdrControl(target, records: LocalMultiplexerRecovery.processes(), deadline: Date().addingTimeInterval(3))
        XCTAssertEqual(observed, saved)
        // A raw-capable server accepts two fresh pipe clients with the same
        // boot identity. EOF closes each bridge; the original server survives.
        let status = try XCTUnwrap(LocalMultiplexerRecovery.run(executable, ["status", "--json"],
            environment: saved.launchEnvironment, deadline: Date().addingTimeInterval(3)))
        let statusJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])
        let capabilities = (statusJSON["server"] as? [String: Any])?["capabilities"] as? [String: Any]
        if (capabilities?["terminal_control_stream"] as? Int ?? 0) > 0 {
            var bootID: String?
            for _ in 0..<2 {
                let output = try XCTUnwrap(LocalMultiplexerRecovery.run(executable, ["control"],
                    environment: saved.launchEnvironment, deadline: Date().addingTimeInterval(3)))
                let first = try XCTUnwrap(output.split(separator: "\n").first)
                let opened = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
                let result = try XCTUnwrap(opened["result"] as? [String: Any])
                let currentBoot = try XCTUnwrap(result["boot_id"] as? String)
                if let bootID { XCTAssertEqual(currentBoot, bootID) }
                bootID = currentBoot
                XCTAssertTrue(LocalMultiplexerRecovery.isAvailable(saved))
            }
        }
        var stale = saved
        stale.serverStartedAt += 1
        XCTAssertFalse(LocalMultiplexerRecovery.isAvailable(stale))
        stale = saved
        stale.socketInode += 1
        XCTAssertFalse(LocalMultiplexerRecovery.isAvailable(stale))
        kill(server.processIdentifier, SIGKILL)
        server.waitUntilExit()
        XCTAssertFalse(LocalMultiplexerRecovery.isAvailable(saved))
    }

    func testProbeUsesExistingLocalePolicy() {
        let output = LocalMultiplexerRecovery.run("/usr/bin/env", [], environment: [:], deadline: Date().addingTimeInterval(3))
        let expected = EnvironmentBuilder().build()["LANG"]
        XCTAssertEqual(output?.split(separator: "\n").first(where: { $0.hasPrefix("LANG=") }).map(String.init), expected.map { "LANG=\($0)" })
    }

    func testProbeDeadlineAlsoCoversClosedStdout() {
        let start = Date()
        XCTAssertNil(LocalMultiplexerRecovery.run("/bin/sh", ["-c", "exec 1>&-; exec /bin/sleep 30"],
            environment: [:], deadline: start.addingTimeInterval(0.2)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTmuxEscapedFields() {
        XCTAssertEqual(LocalMultiplexerRecovery.tmuxRows("42\t$7\t1234\t1\twork\\ name\\\\path\n"),
                       [["42", "$7", "1234", "1", "work name\\path"]])
        XCTAssertTrue(LocalMultiplexerRecovery.tmuxRows("incomplete\\").isEmpty)
    }

    /// Requires an installed tmux. Every server/client belongs to an isolated
    /// test socket; the user's default server is never queried or modified.
    func testLiveTmuxIdentityAndFreshPTYRecovery() throws {
        guard let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("tmux is not installed")
        }
        let directory = "/tmp/rs-recovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = directory + "/socket"
        func tmux(_ arguments: [String]) -> String? {
            LocalMultiplexerRecovery.run(executable, ["-S", socket] + arguments,
                environment: [:], deadline: Date().addingTimeInterval(4))
        }
        defer {
            _ = tmux(["kill-server"])
            try? FileManager.default.removeItem(atPath: directory)
        }
        XCTAssertNotNil(tmux(["-f", "/dev/null", "new-session", "-d", "-s", "original", "/bin/sh"]))

        for controlMode in [false, true] {
            let config = ShellSpawnConfig()
            config.size = PTYSize(rows: 24, cols: 80, xpixel: 0, ypixel: 0)
            config.environment = EnvironmentBuilder().build()
            config.shell = "/bin/zsh -f"
            let client = try ProcessSpawner.spawnShell(with: config)
            // Exercise the normal login parent + shell child ancestry, rather
            // than the custom-command path that execs tmux as the stored PID.
            let arguments = [executable, "-S", socket] + (controlMode ? ["-CC"] : []) + ["attach-session", "-t", "=original"]
            let input = Data((arguments.map(LocalMultiplexerAttachment.quote).joined(separator: " ") + "\n").utf8)
            let written = input.withUnsafeBytes { write(client.pty.masterFD, $0.baseAddress, $0.count) }
            XCTAssertEqual(written, input.count)
            let attachment = try waitForAttachment(client)
            let records = LocalMultiplexerRecovery.processes().filter {
                LocalMultiplexerRecovery.number($0, "pid") != UInt64(client.pid)
            }
            // macOS can deny BSD info for login even to its spawning helper.
            // A readable child PPID and the owned PTY still prove attachment.
            XCTAssertEqual(LocalMultiplexerRecovery.inspect(shellPID: client.pid, pty: client.pty,
                records: records, deadline: Date().addingTimeInterval(4)), attachment)
            XCTAssertNil(LocalMultiplexerRecovery.inspect(shellPID: attachment.serverPID, pty: client.pty,
                records: records, deadline: Date().addingTimeInterval(4)))
            XCTAssertEqual(attachment.controlMode, controlMode)
            XCTAssertEqual(attachment.sessionName, "original")
            XCTAssertEqual(attachment.socketPath, LocalMultiplexerRecovery.canonical(socket))
            XCTAssertTrue(LocalMultiplexerRecovery.isAvailable(attachment))
            var stale = attachment
            stale.serverStartedAt += 1
            XCTAssertFalse(LocalMultiplexerRecovery.isAvailable(stale))
            stale = attachment
            stale.sessionCreatedAt = 1
            XCTAssertFalse(LocalMultiplexerRecovery.isAvailable(stale))
            stopClient(client)

            // A newly attached client supplies a normal -CC preamble; there is
            // no tssh stream resume and the existing server is unchanged.
            let recovery = ShellSpawnConfig()
            recovery.size = config.size
            recovery.environment = config.environment
            recovery.shell = "/bin/zsh -f"
            recovery.recoveryCommand = attachment.attachCommand
            let resumed = try ProcessSpawner.spawnShell(with: recovery)
            defer { stopClient(resumed) }
            let current = try waitForAttachment(resumed)
            XCTAssertEqual(current.serverPID, attachment.serverPID)
            XCTAssertEqual(current.serverStartedAt, attachment.serverStartedAt)
            XCTAssertEqual(current.sessionID, attachment.sessionID)
            XCTAssertEqual(current.controlMode, attachment.controlMode)
        }
    }

    private func waitForAttachment(_ client: ShellSpawnResult) throws -> LocalMultiplexerAttachment {
        let fd = client.pty.masterFD
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(5)
        var buffer = [UInt8](repeating: 0, count: 8192)
        repeat {
            while read(fd, &buffer, buffer.count) > 0 {}
            if let attachment = LocalMultiplexerRecovery.inspect(shellPID: client.pid, pty: client.pty,
                records: LocalMultiplexerRecovery.processes(), deadline: deadline) { return attachment }
            usleep(50_000)
        } while Date() < deadline
        stopClient(client)
        throw NSError(domain: "LocalMultiplexerRecoveryTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No verified attachment appeared on the test PTY"])
    }

    private func stopClient(_ client: ShellSpawnResult) {
        // Closing the PTY hangs up this client, preserving the tmux server.
        client.pty.close()
        _ = kill(client.pid, SIGKILL)
        _ = ProcessSpawner.wait(forProcess: client.pid, blocking: true)
    }
}
