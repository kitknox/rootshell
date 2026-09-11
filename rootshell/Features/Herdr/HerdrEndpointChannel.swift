// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// The stock endpoint's command lane permits one operation at a time. Input
/// and frames stay live while a command waits; no CLI process per scroll tick.
@MainActor
final class HerdrEndpointChannel {
    typealias Wire = HerdrEndpointWire
    typealias Surface = HerdrEndpointSurface

    private let pipe: AsyncBytePipe
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var presentation: Task<Void, Never>?
    private var writes: [Data] = []
    private var queuedBytes = 0
    private var welcomeReceived = false
    private var ready: CheckedContinuation<Void, Error>?
    private var readyTimeout: Task<Void, Never>?
    private var commandTimeout: Task<Void, Never>?
    private var lastPong = Date()
    private var assets: [Surface.AssetKey: Data] = [:]
    private(set) var closed = false
    private(set) var boot: String?
    private(set) var methods: Set<String> = []
    private(set) var capabilities: Set<String> = []
    private(set) var latest: Surface.Frame?

    var onFrame: ((Surface.Frame) -> Void)?
    var onSnapshot: (([String: Any]) -> Void)?
    var onEffect: ((Data) -> Void)?
    var onClosed: ((Error?) -> Void)?

    private struct Command {
        let id = UUID().uuidString
        let method: String
        let params: [String: Any]
        let coalescingKey: String?
        let completion: (Result<Data, Error>) -> Void
    }
    private var commands: [Command] = []
    private var current: Command?
    private var response = Data()

    init(pipe: AsyncBytePipe) { self.pipe = pipe }

    func start(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) async throws {
        let hello = try Wire.hello(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                enqueue(hello)
                readyTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self?.close(error: Wire.Failure.invalid("endpoint handshake timed out"))
                }
                let pipe = pipe
                reader = Task.detached { [weak self] in
                    do {
                        var framer = Wire.Framer()
                        while !Task.isCancelled, let chunk = try await pipe.read(maxBytes: 64 * 1024) {
                            for record in try framer.receive(chunk) {
                                let message = try Surface.decode(record)
                                await self?.receive(message)
                            }
                        }
                        if !Task.isCancelled { await self?.close(error: Wire.Failure.invalid("connection closed")) }
                    } catch {
                        if !Task.isCancelled { await self?.close(error: error) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close(error: CancellationError()) }
        }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            command(method, params) { continuation.resume(with: $0) }
        }
    }

    func command(_ method: String, _ params: [String: Any], coalescingKey: String? = nil,
                 completion: @escaping (Result<Data, Error>) -> Void = { _ in }) {
        guard !closed else { completion(.failure(Wire.Failure.invalid("connection closed"))); return }
        guard methods.contains(method) else {
            completion(.failure(Wire.Failure.invalid("server does not advertise \(method)")))
            return
        }
        if let key = coalescingKey {
            let superseded = commands.filter { $0.coalescingKey == key }
            commands.removeAll { $0.coalescingKey == key }
            for command in superseded { command.completion(.failure(CancellationError())) }
        }
        guard commands.count < 256 else {
            completion(.failure(Wire.Failure.invalid("command queue is full")))
            return
        }
        commands.append(Command(method: method, params: params, coalescingKey: coalescingKey, completion: completion))
        dispatchNext()
    }

    func cancelQueuedScroll(pane: String) {
        let key = "scroll:\(pane)"
        let cancelled = commands.filter { $0.coalescingKey == key }
        commands.removeAll { $0.coalescingKey == key }
        for command in cancelled { command.completion(.failure(CancellationError())) }
    }

    func enqueue(_ bytes: Data) {
        guard !closed else { return }
        guard queuedBytes + bytes.count <= 8 * 1024 * 1024 else {
            close(error: Wire.Failure.invalid("input queue overflow")); return
        }
        writes.append(bytes); queuedBytes += bytes.count
        guard writer == nil else { return }
        writer = Task { [weak self] in
            guard let self else { return }
            defer { self.writer = nil }
            do {
                while !self.closed, !Task.isCancelled, !self.writes.isEmpty {
                    let bytes = self.writes.removeFirst()
                    self.queuedBytes -= bytes.count
                    try await self.pipe.write(bytes)
                }
            } catch { self.close(error: error) }
        }
    }

    func close(error: Error? = nil) {
        guard !closed else { return }
        closed = true
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        heartbeat?.cancel(); heartbeat = nil
        presentation?.cancel(); presentation = nil
        readyTimeout?.cancel(); readyTimeout = nil
        commandTimeout?.cancel(); commandTimeout = nil
        let failure = error ?? Wire.Failure.invalid("connection closed")
        let initial = ready; ready = nil
        initial?.resume(throwing: failure)
        let pending = current.map { [$0] } ?? []
        let all = pending + commands
        current = nil; commands.removeAll(); response.removeAll()
        writes.removeAll(); queuedBytes = 0; latest = nil; assets.removeAll()
        for command in all { command.completion(.failure(failure)) }
        let pipe = pipe
        Task { await pipe.close() }
        onClosed?(error)
    }

    private func dispatchNext() {
        guard !closed, current == nil, let boot, !commands.isEmpty else { return }
        let command = commands.removeFirst()
        current = command
        response.removeAll(keepingCapacity: true)
        do { enqueue(try Wire.request(boot: boot, id: command.id, method: command.method, params: command.params)) }
        catch { finish(.failure(error)); return }
        commandTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            // A timeout is ambiguous. Closing prevents a late response from
            // becoming the acknowledgement of another operation.
            self?.close(error: Wire.Failure.invalid("\(command.method) timed out"))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        commandTimeout?.cancel(); commandTimeout = nil
        let command = current; current = nil
        response.removeAll(keepingCapacity: true)
        command?.completion(result)
        dispatchNext()
    }

    private func receive(_ message: Surface.Message) {
        guard !closed else { return }
        do {
            switch message {
            case .control(let kind, let text):
                if kind == "endpoint.health.pong.v1" { lastPong = Date(); return }
                if kind == "endpoint.presentation.ready.v1" { return }
                guard kind == "endpoint.welcome.v1" || kind == "shell.snapshot.v1" else {
                    if kind.hasPrefix("shell.snapshot.") { throw Wire.Failure.invalid("unsupported snapshot codec") }
                    return
                }
                guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                    throw Wire.Failure.invalid("invalid endpoint JSON")
                }
                if kind == "endpoint.welcome.v1" {
                    if let error = value["error"] as? [String: Any] {
                        throw Wire.Failure.invalid(error["message"] as? String ?? "handshake rejected")
                    }
                    guard value["generation"] as? Int == 1,
                          value["snapshot_codec"] as? String == "shell.snapshot.v1",
                          value["surface_codec"] as? String == "shell.surface.v1",
                          value["input_codec"] as? String == "shell.input.semantic.v1",
                          value["blob_codec"] as? String == "shell.blob.v1" else {
                        throw Wire.Failure.invalid("incompatible endpoint codecs")
                    }
                    methods = Set(value["methods"] as? [String] ?? [])
                    capabilities = Set(value["capabilities"] as? [String] ?? [])
                    guard Set(["pane.scroll", "pane.selection.read", "tab.focus", "pane.focus", "client_shell.surface.set"]).isSubset(of: methods) else {
                        throw Wire.Failure.invalid("vanilla herdr 0.9.0 or newer is required")
                    }
                    welcomeReceived = true
                } else {
                    guard welcomeReceived, let nextBoot = value["boot_id"] as? String, !nextBoot.isEmpty else {
                        throw Wire.Failure.invalid("snapshot arrived before welcome")
                    }
                    if let boot, boot != nextBoot { throw Wire.Failure.invalid("server restarted") }
                    boot = nextBoot
                    onSnapshot?(value)
                    if let initial = ready {
                        ready = nil; readyTimeout?.cancel(); readyTimeout = nil
                        initial.resume()
                        startHeartbeat()
                    }
                    dispatchNext()
                }
            case .frame(var frame):
                guard frame.boot == boot else { throw Wire.Failure.invalid("surface belongs to another server boot") }
                assets.merge(frame.scene.assets, uniquingKeysWith: { _, new in new })
                let live = Set(frame.scene.placements.map(\.asset) + frame.scene.retained)
                assets = assets.filter { live.contains($0.key) }
                guard assets.values.reduce(0, { $0 + $1.count }) <= 64 * 1024 * 1024,
                      frame.scene.placements.allSatisfy({ assets[$0.asset] != nil }) else {
                    throw Wire.Failure.invalid("image scene needs resynchronization")
                }
                frame.scene.assets = assets
                latest = frame
                schedulePresentation()
            case .patch(let patch):
                guard var frame = latest else { throw Wire.Failure.invalid("patch arrived before full frame") }
                try frame.apply(patch)
                latest = frame
                schedulePresentation()
            case .response(let responseBoot, let id, let final, let bytes):
                guard responseBoot == boot, current?.id == id else { return }
                guard response.count + bytes.count <= 8 * 1024 * 1024 else {
                    throw Wire.Failure.invalid("command response too large")
                }
                response.append(bytes)
                if final {
                    if let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                       let error = value["error"] as? [String: Any] {
                        finish(.failure(Wire.Failure.invalid(error["message"] as? String ?? "command failed")))
                    } else { finish(.success(response)) }
                }
            case .clipboard(let encoded):
                guard Data(base64Encoded: encoded) != nil else { return }
                onEffect?(Data("\u{1b}]52;c;\(encoded)\u{7}".utf8))
            case .bell(let count): onEffect?(Data(repeating: 7, count: min(count, 16)))
            case .error(let message): throw Wire.Failure.invalid(message)
            case .shutdown(let message): throw Wire.Failure.invalid(message ?? "server shut down")
            case .ignored: break
            }
        } catch { close(error: error) }
    }

    private func schedulePresentation() {
        guard presentation == nil else { return }
        // Apply every wire patch to `latest`, but paint at most once per
        // display interval. Replaying intermediate scroll frames backlogs
        // Ghostty's parser and stalls input on the main actor.
        presentation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, !self.closed else { return }
            self.presentation = nil
            if let frame = self.latest { self.onFrame?(frame) }
        }
    }

    private func startHeartbeat() {
        guard capabilities.contains("health_check") else { return }
        lastPong = Date()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !self.closed else { return }
                guard Date().timeIntervalSince(self.lastPong) < 20 else {
                    self.close(error: Wire.Failure.invalid("endpoint stopped responding")); return
                }
                if let ping = try? Wire.control("endpoint.health.ping.v1", ["probe": UUID().uuidString]) { self.enqueue(ping) }
            }
        }
    }
}
