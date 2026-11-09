//
//  KVMMediaChannel.swift
//  rootshell
//
//  kvmd-media's `/api/media/ws`: announces formats, streams H.264 access
//  units after `start`, and sends a keyframe on request. Frames go straight
//  to the decoder off the main actor; only lifecycle events hop to main.
//

import Foundation
import os

nonisolated final class KVMMediaChannel: @unchecked Sendable {
    enum Event: Sendable {
        case streaming
        case ended(KVMDError?)
        case roundTrip(TimeInterval)
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "KVM")
    private static let pingInterval: Duration = .seconds(3)
    private static let livenessTimeout: TimeInterval = 10

    private let task: URLSessionWebSocketTask
    private let decoder: KVMH264Decoder
    private let onEvent: @Sendable (Event) -> Void

    private let lock = NSLock()
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var lastPingSent: Date?
    private var lastHeard = Date()
    private var finished = false
    private var receivedBytes = 0
    private var receivedFrames = 0

    init(
        session: URLSession,
        request: URLRequest,
        decoder: KVMH264Decoder,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        task = session.webSocketTask(with: request)
        // A Lossless keyframe at 1440p can exceed the 1 MiB default.
        task.maximumMessageSize = 32 * 1024 * 1024
        self.decoder = decoder
        self.onEvent = onEvent
    }

    func start() {
        task.resume()
        let loop = Task.detached(priority: .userInitiated) { [self] in await receive() }
        lock.withLock { receiveLoop = loop }
    }

    func stop() {
        let loops = lock.withLock {
            finished = true
            return (receiveLoop, pingLoop)
        }
        loops.0?.cancel()
        loops.1?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    func requestKeyframe() {
        task.send(.data(KVMMediaFrame.keyframeRequest)) { _ in }
    }

    /// Bytes and frames received since the last call.
    func drainCounters() -> (bytes: Int, frames: Int) {
        lock.withLock {
            defer {
                receivedBytes = 0
                receivedFrames = 0
            }
            return (receivedBytes, receivedFrames)
        }
    }

    private func receive() async {
        do {
            guard case .string(let announcement) = try await task.receive() else {
                throw KVMDError.protocolError("missing media announcement")
            }
            guard KVMMediaFrame.advertisesH264(announcement) == true else {
                throw KVMDError.directVideoUnavailable
            }
            // The server already starts each new client on a keyframe.
            try await task.send(.string(KVMMediaFrame.startH264Message))
            startPings()
            onEvent(.streaming)

            while !Task.isCancelled {
                let message = try await task.receive()
                lock.withLock { lastHeard = Date() }
                guard case .data(let data) = message else { continue }
                switch KVMMediaFrame.parse(data) {
                case .video(let isKeyframe, let accessUnit):
                    lock.withLock {
                        receivedBytes += data.count
                        receivedFrames += 1
                    }
                    decoder.submit(accessUnit, isKeyframe: isKeyframe)
                case .pong:
                    if let sent = lock.withLock({ lastPingSent }) {
                        onEvent(.roundTrip(Date().timeIntervalSince(sent)))
                    }
                case nil:
                    break
                }
            }
        } catch {
            finish(Self.classify(error, response: task.response))
        }
    }

    private func startPings() {
        let loop = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled else { return }
                let silent = lock.withLock { Date().timeIntervalSince(lastHeard) }
                if silent > Self.livenessTimeout {
                    Self.logger.error("KVM media socket silent for \(Int(silent))s")
                    finish(.timedOut)
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                lock.withLock { lastPingSent = Date() }
                task.send(.data(KVMMediaFrame.ping)) { _ in }
            }
        }
        lock.withLock { pingLoop = loop }
    }

    private func finish(_ error: KVMDError?) {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        lock.withLock { pingLoop }?.cancel()
        onEvent(.ended(error))
    }

    static func classify(_ error: Error, response: URLResponse?) -> KVMDError {
        if let kvmd = error as? KVMDError { return kvmd }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 401, 403: return .unauthorized
        case 404: return .directVideoUnavailable
        case let status?: return .http(status: status, message: nil)
        case nil: break
        }
        if (error as? URLError)?.code == .timedOut { return .timedOut }
        return .protocolError(error.localizedDescription)
    }
}
