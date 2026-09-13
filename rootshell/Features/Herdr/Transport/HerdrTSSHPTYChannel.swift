import Foundation

/// A resizable auxiliary exec channel. Transport.NewSession is reserved for
/// the gateway's one main PTY and must never be used for projected panes.
actor HerdrTSSHPTYChannel: HerdrPTYChannel {
    private let transportRef: TSSHTransportRef
    private let channelRef: Int64
    private let pipe: TrzszExecPipe
    private var closed = false

    private init(transport: TSSHTransportRef, channelRef: Int64) {
        self.transportRef = transport
        self.channelRef = channelRef
        self.pipe = TrzszExecPipe(channelRef: channelRef, transportRef: transport)
    }

    static func open(transport: TSSHTransportRef, command: String, term: String, cols: Int, rows: Int) async throws -> HerdrTSSHPTYChannel {
        let ref = try await TSSHCallGate.shared.openExecPTY(
            on: transport, command: command, term: term, rows: rows, cols: cols
        )
        let pipe = HerdrTSSHPTYChannel(transport: transport, channelRef: ref)
        guard !Task.isCancelled else {
            await pipe.close()
            throw CancellationError()
        }
        return pipe
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await pipe.read(maxBytes: maxBytes)
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw HerdrPTYError.closed }
        try await pipe.write(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard !closed else { throw HerdrPTYError.closed }
        try await TSSHCallGate.shared.execResizePTY(
            on: transportRef, channelRef: channelRef, rows: rows, cols: cols
        )
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await pipe.close()
    }
}
