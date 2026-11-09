//
//  KVMInputQueue.swift
//  rootshell
//
//  Ordered input waiting for the control socket. kvmd turns every HID frame
//  into its own USB report through an unbounded queue, so pointer motion is
//  merged and paced to one frame per interval, as GL's web client does;
//  sending every hover sample makes the remote cursor fall further behind.
//

import Foundation

nonisolated struct KVMInputQueue {
    enum Step: Equatable {
        /// Sent in order: one frame, or the run of motion frames at the head.
        case frames([Data])
        case text(String)
        /// Pointer motion is due again after this many seconds.
        case wait(TimeInterval)
        /// Empty, or held until sends in flight complete.
        case none
    }

    static let motionInterval: TimeInterval = 0.010
    static let maximumFramesInFlight = 32
    /// Motion frames per interval. An interleaved move/scroll run is at most
    /// three; more means a backlog from a paste or a stall.
    static let maximumMotionBatch = 4

    private var items: [KVMInputOutput] = []
    private var lastMotion: TimeInterval?

    var isEmpty: Bool { items.isEmpty }

    mutating func append(_ outputs: [KVMInputOutput]) {
        for output in outputs { append(output) }
    }

    /// Text waits for every earlier frame and later frames wait for the text,
    /// so a held modifier wraps device-typed characters.
    mutating func next(now: TimeInterval, framesInFlight: Int) -> Step {
        guard let head = items.first else { return .none }
        switch head {
        case .text(let text):
            guard framesInFlight == 0 else { return .none }
            items.removeFirst()
            return .text(text)
        case .frame(let frame):
            let budget = Self.maximumFramesInFlight - framesInFlight
            // A full budget means a backed-up socket; motion keeps merging.
            guard budget > 0 else { return .none }
            guard Self.motionOp(frame) != nil else {
                items.removeFirst()
                return .frames([frame])
            }
            // Paced on time alone, like GL's client: waiting on send
            // completions would tie the cursor to how fast they come back.
            if let lastMotion, now - lastMotion < Self.motionInterval {
                return .wait(Self.motionInterval - (now - lastMotion))
            }
            lastMotion = now
            // Moves and scrolls don't merge across each other, so interleaved
            // ones leave together; a backlog drains a batch per interval.
            let run = items.prefix(min(Self.maximumMotionBatch, budget))
                .prefix { Self.motionFrame($0) != nil }
                .compactMap(Self.motionFrame)
            items.removeFirst(run.count)
            return .frames(run)
        }
    }

    mutating func removeText() {
        items.removeAll { if case .text = $0 { true } else { false } }
    }

    mutating func removeAll() {
        items.removeAll()
        lastMotion = nil
    }

    // MARK: Merging

    private mutating func append(_ output: KVMInputOutput) {
        switch output {
        case .text(let text):
            if case .text(let previous)? = items.last {
                items[items.count - 1] = .text(previous + text)
                return
            }
        case .frame(let frame):
            // Only the last item merges: anything else in between (a click, a
            // key, a scroll after a move) must keep the position it had.
            if let op = Self.motionOp(frame), let last = items.last.flatMap(Self.motionFrame),
               last.first == op {
                items[items.count - 1] = .frame(Self.merge(last, frame))
                return
            }
        }
        items.append(output)
    }

    private static let absoluteMoveOp: UInt8 = 0x03

    /// Absolute move, relative move, or wheel.
    private static func motionOp(_ frame: Data) -> UInt8? {
        guard let op = frame.first, (0x03...0x05).contains(op) else { return nil }
        return op
    }

    private static func motionFrame(_ output: KVMInputOutput) -> Data? {
        guard case .frame(let frame) = output, motionOp(frame) != nil else { return nil }
        return frame
    }

    /// The newest absolute position wins; relative and wheel deltas are
    /// concatenated with kvmd's squash flag, which sums them into few reports.
    private static func merge(_ pending: Data, _ newer: Data) -> Data {
        guard pending.first != absoluteMoveOp else { return newer }
        var merged = Data([pending[pending.startIndex], 0x01])
        merged.append(pending.dropFirst(2))
        merged.append(newer.dropFirst(2))
        return merged
    }
}
