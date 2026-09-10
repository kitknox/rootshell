import Foundation

#if targetEnvironment(macCatalyst)
/// Reuses helper PTY monitoring, resize and process cleanup. No helper wire
/// change is needed: its shell field already accepts a quoted shell command.
@MainActor
final class HerdrLocalPTYChannel: HerdrPTYChannel {
    private nonisolated let output = HerdrPTYOutputBuffer()
    private var session: CatalystLocalShellSession?

    static func open(command: String, cols: Int, rows: Int, paneToken: String) async throws -> HerdrLocalPTYChannel {
        let shell = "/bin/zsh -lc " + LoginShellCommand.singleQuoted("exec " + command)
        // The helper rejects longer shell commands by launching a normal shell.
        // Detect that here instead of silently attaching an unrelated shell.
        guard shell.count <= 1024 else {
            throw HerdrPTYError.unavailable("herdr PTY command exceeds the helper's shell command limit")
        }
        let session: CatalystLocalShellSession = try await withCheckedThrowingContinuation { ready in
            CatalystLocalShellSession.create(
                rows: UInt16(clamping: rows), cols: UInt16(clamping: cols), shell: shell,
                enableShellIntegration: false, paneToken: paneToken
            ) { ready.resume(with: $0) }
        }
        guard !Task.isCancelled else {
            session.stop()
            throw CancellationError()
        }
        let pipe = HerdrLocalPTYChannel()
        pipe.session = session
        let output = pipe.output
        session.onOutputData = { [weak pipe] data in
            if !output.append(data) { Task { @MainActor in await pipe?.close() } }
        }
        session.onSessionEnd = { output.finish() }
        session.onError = { output.finish(error: $0) }
        session.startMonitoring()
        return pipe
    }

    nonisolated func read(maxBytes: Int) async throws -> Data? {
        try await output.read(maxBytes: maxBytes)
    }

    func write(_ data: Data) async throws {
        guard let session, session.isRunning else { throw HerdrPTYError.closed }
        session.sendInput(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard let session, session.isRunning else { throw HerdrPTYError.closed }
        try session.setSize(TerminalPTY.TerminalSize(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols)))
    }

    func close() async {
        output.finish(discard: true)
        session?.onSessionEnd = nil
        session?.onError = nil
        session?.stop()
        session = nil
    }
}
#endif
