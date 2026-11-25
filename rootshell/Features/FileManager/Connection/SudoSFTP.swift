//
//  SudoSFTP.swift
//  rootshell
//
//  Sudo mode: runs sftp-server under `sudo -S` on an exec channel of an
//  existing SFTP connection. Prompts arrive on stderr and answers go to
//  stdin; the server's own "session opened" log line proves sudo let it
//  start, and only then does SFTP begin on stdout.
//

import Foundation
@preconcurrency import Citadel

/// An exec channel with stderr split from the byte pipe.
nonisolated struct RemoteExecChannel: Sendable {
    let pipe: AsyncBytePipe
    let stderr: AsyncStream<Data>
}

/// One question from sudo or PAM, shown by the file manager.
nonisolated struct SudoPrompt: Sendable, Identifiable {
    let id = UUID()
    let host: String
    /// Whose password sudo wants (`%p`), for its own password prompt.
    let account: String?
    /// A PAM prompt other than sudo's password prompt, verbatim.
    let promptText: String?
    let isRetry: Bool
    /// Messages printed since the last answer (PAM info, Duo, the lecture).
    let info: [String]

    var isPassword: Bool { promptText == nil }
}

/// Splits sudo's stderr into prompts, retries, messages and the ready line.
nonisolated struct SudoStderrParser {
    enum Event: Equatable {
        case ready
        case retry
        case info(String)
        case passwordPrompt(account: String?)
        case otherPrompt(String)
    }

    static let readyMarker = "session opened for local user"
    /// stderr comes from the server, so retained state is bounded.
    static let maxLineLength = 4096
    static let maxLines = 32

    struct Overflow: Error {}

    private var buffer = Data()
    private var tailReported = false
    private(set) var transcript: [String] = []
    private(set) var infoSinceAnswer: [String] = []

    /// Throws `Overflow` for any line over `maxLineLength` bytes, terminated or not.
    mutating func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            guard newline - buffer.startIndex <= Self.maxLineLength else { throw Overflow() }
            let line = Self.text(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            // A reported prompt that later gets a newline was already handled.
            let wasReported = tailReported
            tailReported = false
            if wasReported || line.isEmpty { continue }
            if line.contains(Self.readyMarker) {
                events.append(.ready)
            } else if line.hasPrefix("Sorry, try again") {
                events.append(.retry)
            } else {
                Self.append(line, to: &transcript)
                Self.append(line, to: &infoSinceAnswer)
                events.append(.info(line))
            }
        }
        guard buffer.count <= Self.maxLineLength else { throw Overflow() }
        if !tailReported, let prompt = markerPrompt() {
            tailReported = true
            events.append(prompt)
        }
        return events
    }

    /// The unterminated tail after a quiet spell: a PAM prompt without the marker.
    mutating func idle() -> Event? {
        guard !tailReported else { return nil }
        let tail = Self.text(buffer)
        guard !tail.isEmpty, !tail.contains(SFTPServerLauncher.sudoPromptMarker) else { return nil }
        tailReported = true
        return .otherPrompt(tail)
    }

    /// Drops the prompt just answered; sudo prints no newline after `-S` input.
    mutating func answered() {
        buffer = Data()
        tailReported = false
        infoSinceAnswer = []
    }

    /// Why sudo exited without starting the server.
    func failure(host: String) -> FileManagerConnectionError {
        let lines = transcript + [Self.text(buffer)].filter { !$0.isEmpty }
        if lines.contains(where: { $0.contains("must have a tty") || $0.contains("a terminal is required") }) {
            return .sudoRequiresTTY(host: host)
        }
        if lines.contains(where: { $0.contains("sudo") && ($0.contains("not found") || $0.contains("No such file")) }) {
            return .sudoFailed(host: host, message: String(localized: "sudo isn't installed.", comment: "File manager sudo error"))
        }
        guard var last = lines.last(where: { !$0.contains(SFTPServerLauncher.sudoPromptMarker) }) else {
            return .sudoFailed(host: host, message: String(localized: "sftp-server didn't start.", comment: "File manager sudo error"))
        }
        if last.hasPrefix("sudo: ") { last.removeFirst("sudo: ".count) }
        return .sudoFailed(host: host, message: last)
    }

    /// `ROOTSHELL_SUDO_PROMPT:<account>:` once the closing colon has arrived.
    private func markerPrompt() -> Event? {
        let tail = Self.text(buffer)
        guard let range = tail.range(of: SFTPServerLauncher.sudoPromptMarker),
              let end = tail[range.upperBound...].firstIndex(of: ":")
        else { return nil }
        let account = String(tail[range.upperBound..<end])
        return .passwordPrompt(account: account.isEmpty ? nil : account)
    }

    private static func append(_ line: String, to lines: inout [String]) {
        if lines.count >= maxLines { lines.removeFirst(lines.count - maxLines + 1) }
        lines.append(line)
    }

    private static func text(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum SudoSFTP {
    /// Quiet time before an unterminated stderr tail counts as a PAM prompt.
    private static let promptSettle: Duration = .milliseconds(300)
    /// Limit on waiting for sudo when no prompt is on screen (a Duo push takes a while).
    private static let responseTimeout: Duration = .seconds(120)

    /// Opens a root SFTP connection on `base`'s transport. `release` runs when
    /// it closes; the base connection itself stays open.
    static func open(
        base: SFTPConnection,
        host: String,
        label: String,
        prompts: FileManagerPrompts,
        release: @escaping @Sendable () async -> Void
    ) async throws -> SFTPConnection {
        guard let openExec = base.openExec else { throw FileManagerConnectionError.sudoUnavailable }
        let serverPath = try await locateServer(openExec, host: host)
        let password = PasswordCache()

        let browseClient = try await launch(openExec, serverPath: serverPath, host: host) { prompt in
            let answer = await prompts.sudo(prompt)
            if prompt.isPassword, let answer { await password.store(answer) }
            return answer
        }
        // Extra channels answer only sudo's password prompt, with the password
        // that just worked; anything else falls back to the browse channel.
        let openChannel: @Sendable () async throws -> SFTPClient = {
            try await launch(openExec, serverPath: serverPath, host: host) { prompt in
                guard prompt.isPassword, !prompt.isRetry else { return nil }
                return await password.value
            }
        }
        return SFTPConnection(
            browseClient: browseClient,
            label: label,
            login: base.login,
            isSudo: true,
            openChannel: openChannel,
            teardown: release
        )
    }

    /// The server path, found as the login user so sudo runs the binary
    /// itself and path-restricted sudoers rules match.
    private static func locateServer(
        _ openExec: @Sendable (String) async throws -> RemoteExecChannel,
        host: String
    ) async throws -> String {
        let exec = try await openExec(SFTPServerLauncher.locateCommand())
        let drain = Task { for await _ in exec.stderr {} }
        defer { drain.cancel() }
        let pipe = exec.pipe
        let output: Data
        do {
            output = try await withTimeout(seconds: 15) {
                var output = Data()
                while output.count < 4096, let chunk = try await pipe.read(maxBytes: 4096) {
                    output.append(chunk)
                }
                return output
            }
        } catch {
            await pipe.close()
            throw error
        }
        await pipe.close()
        let path = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard path.hasPrefix("/") else { throw FileManagerConnectionError.sftpServerMissing(host: host) }
        return path
    }

    private static func launch(
        _ openExec: @Sendable (String) async throws -> RemoteExecChannel,
        serverPath: String,
        host: String,
        answer: @escaping @Sendable (SudoPrompt) async -> String?
    ) async throws -> SFTPClient {
        let exec = try await openExec(SFTPServerLauncher.sudoCommand(serverPath: serverPath))
        do {
            try await authenticate(exec, host: host, answer: answer)
            return try await SFTPConnectionFactory.sftpClient(over: exec.pipe, host: host)
        } catch {
            await exec.pipe.close()
            throw error
        }
    }

    private enum Input: Sendable {
        case data(Data)
        case settled
        case timedOut
        case ended
    }

    /// Answers prompts until the server announces itself. stderr keeps being
    /// drained afterwards: tssh stalls on unread stderr, and the server logs there.
    private static func authenticate(
        _ exec: RemoteExecChannel,
        host: String,
        answer: @escaping @Sendable (SudoPrompt) async -> String?
    ) async throws {
        let (inputs, sink) = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingNewest(64))
        Task {
            var settle: Task<Void, Never>?
            for await chunk in exec.stderr {
                settle?.cancel()
                sink.yield(.data(chunk))
                settle = Task {
                    try? await Task.sleep(for: SudoSFTP.promptSettle)
                    if !Task.isCancelled { sink.yield(.settled) }
                }
            }
            settle?.cancel()
            sink.yield(.ended)
            sink.finish()
        }
        func startDeadline() -> Task<Void, Never> {
            Task {
                try? await Task.sleep(for: SudoSFTP.responseTimeout)
                if !Task.isCancelled { sink.yield(.timedOut) }
            }
        }

        var parser = SudoStderrParser()
        var isRetry = false
        var deadline = startDeadline()
        defer { deadline.cancel() }

        for await input in inputs {
            let events: [SudoStderrParser.Event]
            switch input {
            case .data(let data):
                do {
                    events = try parser.feed(data)
                } catch {
                    throw FileManagerConnectionError.sudoFailed(
                        host: host,
                        message: String(localized: "sudo printed a line that's too long.", comment: "File manager sudo error")
                    )
                }
            case .settled: events = parser.idle().map { [$0] } ?? []
            case .timedOut:
                throw FileManagerConnectionError.sudoFailed(
                    host: host,
                    message: String(localized: "sudo didn't respond.", comment: "File manager sudo error")
                )
            case .ended: throw parser.failure(host: host)
            }
            for event in events {
                let prompt: SudoPrompt
                switch event {
                case .ready:
                    return
                case .retry:
                    isRetry = true
                    continue
                case .info:
                    continue
                case .passwordPrompt(let account):
                    prompt = SudoPrompt(host: host, account: account, promptText: nil, isRetry: isRetry, info: parser.infoSinceAnswer)
                case .otherPrompt(let text):
                    prompt = SudoPrompt(host: host, account: nil, promptText: text, isRetry: isRetry, info: parser.infoSinceAnswer)
                }
                deadline.cancel()
                guard let reply = await answer(prompt) else { throw FileManagerConnectionError.cancelled }
                isRetry = false
                parser.answered()
                try await exec.pipe.write(Data((reply + "\n").utf8))
                deadline = startDeadline()
            }
        }
        try Task.checkCancellation()
        throw parser.failure(host: host)
    }

    private actor PasswordCache {
        private(set) var value: String?
        func store(_ password: String) { value = password }
    }
}
