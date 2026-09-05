#if !targetEnvironment(macCatalyst)

import Foundation

/// Progress flags shared by Git commands that expose libgit2 callbacks.
nonisolated struct GitProgressControl: Sendable {
    private(set) var quiet = false
    private var explicitProgress: Bool?

    /// Consume a progress-related command-line option.
    mutating func consume(_ argument: String) -> Bool {
        switch argument {
        case "-q", "--quiet":
            quiet = true
            return true
        case "--progress":
            explicitProgress = true
            return true
        case "--no-progress":
            explicitProgress = false
            return true
        default:
            return false
        }
    }

    func isEnabled(default defaultValue: Bool) -> Bool {
        !quiet && (explicitProgress ?? defaultValue)
    }
}

/// A Git command whose human-readable status and progress have their own
/// output channel. The ios_system bridge maps this channel to stderr, while
/// the direct interactive path maps both channels to the terminal.
protocol GitProgressSubcommand: GitSubcommand {
    static func run(
        repo: OpaquePointer?,
        args: [String],
        cols: UInt16,
        output: @escaping @Sendable (String) -> Void,
        statusOutput: @escaping @Sendable (String) -> Void,
        progressDefault: Bool
    ) throws -> Int32
}

extension GitProgressSubcommand {
    static func run(
        repo: OpaquePointer?,
        args: [String],
        cols: UInt16,
        output: @escaping @Sendable (String) -> Void
    ) throws -> Int32 {
        try run(
            repo: repo,
            args: args,
            cols: cols,
            output: output,
            statusOutput: output,
            progressDefault: true
        )
    }
}

/// Limits terminal repaint traffic while preserving useful byte-count updates
/// during a long percentage step. The latest suppressed update is flushed by
/// `finish()` so a command never ends on stale progress.
nonisolated final class GitProgressReporter: @unchecked Sendable {
    typealias Clock = @Sendable () -> UInt64

    private nonisolated struct Update: Equatable {
        let phase: String
        let label: String
        let current: Int
        let total: Int
        let suffix: String
    }

    private let enabled: Bool
    private let cols: UInt16
    private let output: @Sendable (String) -> Void
    private let now: Clock
    private let minimumIntervalNanoseconds: UInt64
    private let lock = NSLock()

    private var lastReceived: Update?
    private var lastEmitted: Update?
    private var lastEmissionTime: UInt64?
    private var hasRendered = false
    private var isFinished = false

    init(
        enabled: Bool,
        cols: UInt16,
        minimumIntervalNanoseconds: UInt64 = 100_000_000,
        now: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        output: @escaping @Sendable (String) -> Void
    ) {
        self.enabled = enabled
        self.cols = cols
        self.minimumIntervalNanoseconds = minimumIntervalNanoseconds
        self.now = now
        self.output = output
    }

    func report(
        phase: String,
        label: String? = nil,
        current: Int,
        total: Int,
        suffix: String = ""
    ) {
        guard enabled, total > 0 else { return }

        let update = Update(
            phase: phase,
            label: label ?? phase,
            current: current,
            total: total,
            suffix: suffix
        )

        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return }
        guard update != lastReceived else { return }
        lastReceived = update

        let timestamp = now()
        let phaseChanged = lastEmitted?.phase != update.phase
        let completed = update.current >= update.total && !(
            lastEmitted?.phase == update.phase &&
            (lastEmitted?.current ?? 0) >= (lastEmitted?.total ?? 1)
        )
        let intervalElapsed: Bool
        if let lastEmissionTime {
            intervalElapsed = timestamp &- lastEmissionTime >= minimumIntervalNanoseconds
        } else {
            intervalElapsed = true
        }

        guard phaseChanged || completed || intervalElapsed else { return }
        emit(update, at: timestamp)
    }

    /// Flush the newest throttled update and terminate the in-place progress
    /// line. No output is produced when progress was disabled or never shown.
    func finish() {
        guard enabled else { return }

        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return }
        isFinished = true
        if let lastReceived, lastReceived != lastEmitted {
            emit(lastReceived, at: now())
        }
        if hasRendered {
            output("\r\n")
        }
    }

    private func emit(_ update: Update, at timestamp: UInt64) {
        output(GitStyle.formatProgressLine(
            label: update.label,
            current: update.current,
            total: update.total,
            cols: cols,
            suffix: update.suffix
        ))
        lastEmitted = update
        lastEmissionTime = timestamp
        hasRendered = true
    }
}

/// Deterministic on-device checks, exposed through `shelltest git-progress`.
/// Keeping these beside the reporter lets the app exercise the production
/// implementation without requiring a network clone or a separate app test
/// target.
nonisolated enum GitProgressSelfTest {
    private nonisolated final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func now() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(milliseconds: UInt64) {
            lock.lock()
            value += milliseconds * 1_000_000
            lock.unlock()
        }
    }

    private nonisolated final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return values.count
        }

        var last: String? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    static func run() -> [String] {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let clock = TestClock()
        let capture = Capture()
        let reporter = GitProgressReporter(
            enabled: true,
            cols: 80,
            now: { clock.now() },
            output: { capture.append($0) }
        )

        reporter.report(phase: "Receiving", current: 1, total: 100)
        expect(capture.count == 1, "first update was not emitted")

        clock.advance(milliseconds: 200)
        reporter.report(phase: "Receiving", current: 1, total: 100)
        expect(capture.count == 1, "exact duplicate was emitted")

        reporter.report(phase: "Receiving", current: 2, total: 100)
        expect(capture.count == 2, "elapsed update was not emitted")

        clock.advance(milliseconds: 50)
        reporter.report(phase: "Receiving", current: 3, total: 100)
        expect(capture.count == 2, "sub-100ms update was not throttled")

        reporter.report(phase: "Indexing", current: 1, total: 100)
        expect(capture.count == 3, "phase change was not emitted immediately")

        reporter.report(phase: "Indexing", current: 100, total: 100)
        expect(capture.count == 4, "completion was not emitted immediately")
        reporter.report(phase: "Indexing", current: 100, total: 100, suffix: " done")
        expect(capture.count == 4, "repeated completion bypassed throttling")

        reporter.report(phase: "Checkout", current: 1, total: 10)
        reporter.report(phase: "Checkout", current: 2, total: 10)
        let beforeFinish = capture.count
        reporter.finish()
        expect(capture.count == beforeFinish + 2, "finish did not flush pending progress and newline")
        expect(capture.last == "\r\n", "finish did not terminate the progress line")
        let afterFinish = capture.count
        reporter.finish()
        expect(capture.count == afterFinish, "finish was not idempotent")

        let disabledCapture = Capture()
        let disabled = GitProgressReporter(
            enabled: false,
            cols: 80,
            now: { clock.now() },
            output: { disabledCapture.append($0) }
        )
        disabled.report(phase: "Receiving", current: 1, total: 2)
        disabled.finish()
        expect(disabledCapture.count == 0, "disabled progress produced output")

        var quiet = GitProgressControl()
        _ = quiet.consume("--progress")
        _ = quiet.consume("--quiet")
        expect(!quiet.isEnabled(default: true), "quiet did not override --progress")

        var forced = GitProgressControl()
        _ = forced.consume("--progress")
        expect(forced.isEnabled(default: false), "--progress did not override the default")

        var suppressed = GitProgressControl()
        _ = suppressed.consume("--no-progress")
        expect(!suppressed.isEnabled(default: true), "--no-progress did not override the default")

        return failures
    }
}

#endif
