//
//  TailnetPathMonitor.swift
//  rootshell
//
//  Tells the in-app Tailscale engine which physical interface carries the
//  network. Tailscale on iOS can't see this itself; the official app and our
//  VPN extension feed it the same way. Without it, a Wi-Fi to cellular move
//  leaves the engine on sockets for a network that is gone.
//

#if !CHINA_BUILD

import Foundation
import Network
import os

nonisolated final class TailnetPathMonitor: @unchecked Sendable {
    static let shared = TailnetPathMonitor()

    private let queue = DispatchQueue(label: "com.rootshell.tailnet.path")
    // Queue-confined.
    private var monitor: NWPathMonitor?
    private var published: String?
    private var pendingRecheck: DispatchWorkItem?

    /// Starts watching and reports the current interface before returning,
    /// so the engine starts on the right network (waits at most a second).
    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable () -> Void = {
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume() }
            }
            queue.async { [self] in
                guard monitor == nil else { return resumeOnce() }
                let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
                self.monitor = monitor
                monitor.pathUpdateHandler = { [weak self] path in
                    self?.publish(path, force: false)
                    resumeOnce()
                }
                monitor.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 1, execute: resumeOnce)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            pendingRecheck?.cancel()
            pendingRecheck = nil
            monitor?.cancel()
            monitor = nil
            published = nil
        }
    }

    /// Asks Tailscale to re-check its network, e.g. back from the background.
    /// The cached path can lag a change made while suspended, so it checks
    /// again once the monitor has caught up — only publishing on that follow-up
    /// if the interface actually changed, avoiding a redundant second rebind.
    func refresh(forceImmediate: Bool = true) {
        queue.async { [self] in
            if let path = monitor?.currentPath { publish(path, force: forceImmediate) }
            pendingRecheck?.cancel()
            let recheck = DispatchWorkItem { [weak self] in
                guard let self, let path = self.monitor?.currentPath else { return }
                self.pendingRecheck = nil
                self.publish(path, force: false)
            }
            pendingRecheck = recheck
            queue.asyncAfter(deadline: .now() + 2, execute: recheck)
        }
    }

    private func publish(_ path: NWPath, force: Bool) {
        let physical: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular]
        let name = path.status == .satisfied
            ? path.availableInterfaces.first { physical.contains($0.type) }?.name ?? ""
            : ""
        guard force || name != published else { return }
        published = name
        TailnetInAppEngine.debugLog("default interface \(name.isEmpty ? "none" : name)\(force ? " (refresh)" : "")")
        TailnetGo.defaultInterfaceChanged(name)
    }
}

#endif
