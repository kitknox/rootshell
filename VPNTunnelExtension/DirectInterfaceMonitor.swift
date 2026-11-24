//
//  DirectInterfaceMonitor.swift
//  VPNTunnelExtension
//
//  Keeps Direct-mode sockets pinned to the physical interface. Without it the
//  provider's own upstream connections follow its default route back into the
//  tunnel and loop, so nothing reaches the internet.
//

import Foundation
import Network
import os
@preconcurrency import TsshKit

nonisolated final class DirectInterfaceMonitor: @unchecked Sendable {
    static let shared = DirectInterfaceMonitor()

    private let queue = DispatchQueue(label: "VPNTunnel.directInterface")
    // Queue-confined.
    private var monitor: NWPathMonitor?
    private var latestPath: NWPath?
    private var recheck: DispatchWorkItem?
    private var published = -1

    /// Starts monitoring and returns the first physical interface index (0 if
    /// none appeared within a moment). Later path changes update Go directly.
    func start() async -> Int {
        stop()
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        queue.sync { self.monitor = monitor }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (Int) -> Void = { index in
                let first = resumed.withLock { flag in
                    defer { flag = true }
                    return !flag
                }
                if first { continuation.resume(returning: index) }
            }
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.latestPath = path
                resumeOnce(self.apply(path, attempt: 0))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) { resumeOnce(0) }
        }
    }

    func stop() {
        queue.sync {
            monitor?.cancel()
            monitor = nil
            latestPath = nil
            recheck?.cancel()
            recheck = nil
            published = -1
        }
        VpntunnelSetDirectInterface(0)
    }

    /// Picks the interface that really carries a default route and hands it to
    /// Go. The routing table can lag a path change, so while none qualifies it
    /// checks again for a few seconds; Direct dials fail until one does.
    private func apply(_ path: NWPath, attempt: Int) -> Int {
        recheck?.cancel()
        recheck = nil
        let physical: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular]
        let candidates = path.availableInterfaces
            .filter { physical.contains($0.type) }
            .map { String($0.index) }
        let index = candidates.isEmpty ? 0 : VpntunnelPickDirectInterface(candidates.joined(separator: ","))
        if index != published {
            published = index
            VpntunnelSetDirectInterface(index)
        }
        if index == 0, !candidates.isEmpty, attempt < 10 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let path = self.latestPath else { return }
                _ = self.apply(path, attempt: attempt + 1)
            }
            recheck = work
            queue.asyncAfter(deadline: .now() + 1, execute: work)
        }
        return index
    }
}
