// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Captures for native fallback tabs. The exposé display link supplies demand;
/// there is no polling timer left running after the presentation stops.
@MainActor
final class HerdrFallbackPreviewFeed: MuxPreviewFrameSource {
    struct Context: Equatable {
        let generation: UUID
        let endpointID: ObjectIdentifier?
        let selectedTabID: UUID?
        let tabs: [MuxTab]
        let paneIdentities: [String: String]
        var attachment: LocalMultiplexerAttachment? = nil
    }

    weak var ghosttyApp: Ghostty.App?
    let type: MultiplexerType? = .herdr
    let confirmsPreviewParserGrid = true
    private let contextProvider: (Set<String>) -> Context?
    private let capture: (MuxTickRequest) async throws -> MuxTickResult
    private let now: () -> TimeInterval
    private var context: Context?
    private var requestedTabs: Set<String> = []
    private var tabs: [String: MuxTab] = [:]
    private var frames: [String: MuxPaneFrame] = [:]
    private var lastFetch: [String: TimeInterval] = [:]
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var nextCaptureAt: TimeInterval = 0
    private var interval: TimeInterval = 0.4
    private var fetchCap = Int.max
    private var cleanTicks = 0

    init(ghosttyApp: Ghostty.App?,
         context: @escaping (Set<String>) -> Context?,
         capture: @escaping (MuxTickRequest) async throws -> MuxTickResult,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.ghosttyApp = ghosttyApp
        self.contextProvider = context
        self.capture = capture
        self.now = now
    }

    deinit { task?.cancel() }

    func frame(for paneID: String) -> MuxPaneFrame? { frames[paneID] }

    func tab(for id: String) -> MuxTab? {
        guard let tab = tabs[id], tab.panes.contains(where: { frames[$0.id] != nil }) else { return nil }
        return tab
    }

    func update(visibleTabIDs: Set<String>) {
        guard !visibleTabIDs.isEmpty, let current = contextProvider(visibleTabIDs), !current.tabs.isEmpty else {
            stop()
            return
        }
        if current != context || visibleTabIDs != requestedTabs {
            revision &+= 1
            task?.cancel()
            // Keep the task until its cancelled pipe has finished closing.
            // Repeated display ticks must not start overlapping batches.
            if context?.generation != current.generation || context?.endpointID != current.endpointID
                || context?.attachment != current.attachment {
                tabs.removeAll()
                frames.removeAll()
                lastFetch.removeAll()
            } else {
                let oldTabs = Dictionary(uniqueKeysWithValues: (context?.tabs ?? []).map { ($0.id, $0) })
                for tab in current.tabs where oldTabs[tab.id] != tab {
                    tabs.removeValue(forKey: tab.id)
                    for pane in tab.panes { frames.removeValue(forKey: pane.id) }
                }
                for (pane, terminal) in current.paneIdentities where context?.paneIdentities[pane] != terminal {
                    frames.removeValue(forKey: pane)
                }
            }
            let livePanes = Set(current.tabs.flatMap { $0.panes.map(\.id) })
            frames = frames.filter { livePanes.contains($0.key) }
            lastFetch = lastFetch.filter { livePanes.contains($0.key) }
            let liveTabs = Set(current.tabs.map(\.id))
            tabs = tabs.filter { liveTabs.contains($0.key) }
            context = current
            requestedTabs = visibleTabIDs
            nextCaptureAt = 0
            interval = 0.4
        }
        guard task == nil, now() >= nextCaptureAt else { return }
        let candidates = current.tabs.flatMap { $0.panes.filter(\.isPreviewable).map(\.id) }
        let fetch = Array(Set(candidates)).sorted {
            let lhs = lastFetch[$0] ?? -.infinity, rhs = lastFetch[$1] ?? -.infinity
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        let request = MuxTickRequest(fetch: Array(fetch.prefix(fetchCap)), knownRevisions: frames.mapValues(\.revision))
        let revision = self.revision
        let capture = self.capture
        let startedAt = now()
        task = Task { [weak self] in
            let result: Result<MuxTickResult, Error>
            do { result = .success(try await capture(request)) }
            catch { result = .failure(error) }
            guard let self else { return }
            defer { self.task = nil }
            guard !Task.isCancelled, self.revision == revision,
                  self.contextProvider(self.requestedTabs) == current else { return }
            switch result {
            case .success(let value):
                self.apply(value, requested: request)
                self.interval = 0.4
                self.nextCaptureAt = max(self.now(), startedAt + self.interval)
            case .failure:
                self.interval = min(self.interval * 1.5, 2.5)
                self.nextCaptureAt = self.now() + self.interval
            }
        }
    }

    private func apply(_ result: MuxTickResult, requested: MuxTickRequest) {
        // The generic API snapshot describes the server TUI's viewport, not
        // our endpoint. Keep the native layout and verify server ownership and
        // terminal identity before accepting content under a public pane ID.
        let capturedTabs = (context?.tabs ?? []).filter { tab in
            guard requestedTabs.contains(tab.id),
                  let captured = result.snapshot.tab(withID: tab.id) else { return false }
            let serverPanes = Set(captured.panes.map(\.id))
            return tab.panes.allSatisfy { pane in
                serverPanes.contains(pane.id) && context?.paneIdentities[pane.id] != nil
                    && result.paneIdentities[pane.id] == context?.paneIdentities[pane.id]
            }
        }
        let live = Set(capturedTabs.flatMap { $0.panes.map(\.id) })
        let fetched = Set(requested.fetch)
        for tab in capturedTabs {
            // A partial batch cannot keep a frame drawn for a previous grid.
            let previous = Dictionary(uniqueKeysWithValues: (tabs[tab.id]?.panes ?? []).map { ($0.id, $0.rect) })
            for pane in tab.panes where previous[pane.id] != pane.rect {
                frames.removeValue(forKey: pane.id)
            }
        }
        tabs = Dictionary(uniqueKeysWithValues: capturedTabs.map { ($0.id, $0) })
        frames = frames.filter { live.contains($0.key) }
        for (id, frame) in result.frames where live.contains(id) && fetched.contains(id) && !frame.ansi.isEmpty {
            frames[id] = frame
        }
        for id in requested.fetch { lastFetch[id] = now() }
        if result.truncated {
            fetchCap = max(1, min(fetchCap, max(requested.fetch.count, 2)) / 2)
            cleanTicks = 0
        } else {
            cleanTicks += 1
            if cleanTicks >= 5, fetchCap != Int.max {
                fetchCap = fetchCap >= Int.max / 2 ? Int.max : fetchCap * 2
                cleanTicks = 0
            }
        }
    }

    func stop() {
        guard context != nil || !requestedTabs.isEmpty else { return }
        revision &+= 1
        task?.cancel()
        context = nil
        requestedTabs.removeAll()
        tabs.removeAll()
        frames.removeAll()
        lastFetch.removeAll()
        nextCaptureAt = 0
        interval = 0.4
        fetchCap = Int.max
        cleanTicks = 0
    }
}
