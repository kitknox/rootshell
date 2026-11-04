import Foundation

/// Keeps the latest layout pending until its WindowChange succeeds. Only one
/// resize sequence can run at a time, including the two steps of a forced redraw.
@MainActor
final class TSSHResizeController {
    struct Size: Equatable, Sendable {
        let cols: Int
        let rows: Int
    }

    private let send: @MainActor (Size) async throws -> Void
    private var requested: Size?
    private var sent: Size?
    private var redrawRequested = false
    private var task: Task<Void, Never>?
    private var generation = 0

    init(send: @escaping @MainActor (Size) async throws -> Void) {
        self.send = send
    }

    /// The returned task drains all layouts requested while it is in flight.
    @discardableResult
    func request(_ size: Size, forceRedraw: Bool = false) -> Task<Void, Never>? {
        guard size.cols > 0, size.rows > 0 else { return nil }
        requested = size
        redrawRequested = redrawRequested || forceRedraw
        if let task { return task }
        guard requested != sent || redrawRequested else { return nil }

        let generation = self.generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while let size = self.requested, size != self.sent || self.redrawRequested {
                let redraw = self.redrawRequested
                self.redrawRequested = false
                do {
                    try Task.checkCancellation()
                    if redraw {
                        let temporary = Size(cols: size.cols > 1 ? size.cols - 1 : size.cols + 1,
                                             rows: size.rows)
                        try await self.send(temporary)
                        // Let the remote TUI process SIGWINCH before restoring
                        // the real size; back-to-back signals can coalesce.
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try Task.checkCancellation()
                    try await self.send(size)
                    guard generation == self.generation else { return }
                    self.sent = size
                } catch {
                    guard generation == self.generation else { return }
                    // A failed resize must not suppress an identical retry.
                    self.sent = nil
                    self.redrawRequested = self.redrawRequested || redraw
                    break
                }
            }
            guard generation == self.generation else { return }
            self.task = nil
        }
        self.task = task
        return task
    }

    /// A replacement PTY has its own dimensions; don't carry over old work.
    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        requested = nil
        sent = nil
        redrawRequested = false
    }
}
