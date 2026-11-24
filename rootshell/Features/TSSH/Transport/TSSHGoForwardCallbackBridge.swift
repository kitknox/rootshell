//
//  TSSHGoForwardCallbackBridge.swift
//  rootshell
//
//  Reverse-binding bridge for Go's `ForwardCallback` interface. Go goroutines
//  call into this class synchronously via gomobile; the bridge buffers events
//  while the app is backgrounded / in the resume quiet window, then drains
//  them onto the main actor and into `TrzszPortForwardManager`.
//
//  This bridge does NOT make Swift→Go calls — it is exempt from the
//  `TSSHCallGate` chokepoint by design. See TSSHCallGate.swift for the
//  invariant.
//

import Foundation
import os
import OSLog
#if CHINA_BUILD || targetEnvironment(macCatalyst)
@preconcurrency import TrzszSSH
#else
@preconcurrency import TsshKit
#endif

/// Marshalled-on-the-bridge representation of a single forward callback.
enum ForwardCallbackEvent: Sendable {
    case ready(idString: String, actualPort: Int)
    case error(idString: String, message: String)
    case stopped(idString: String)
    case opened(idString: String, connectionID: Int64)
    case closed(idString: String, connectionID: Int64, bytesIn: Int64, bytesOut: Int64)
}

/// Bridges Go's `ForwardCallback` to `TrzszPortForwardManager`. Delivers
/// callbacks while the app is processing in the background; buffers them only
/// while parked or in the resume quiet window.
nonisolated final class TrzszGoForwardCallbackBridge: NSObject, IosbridgeForwardCallbackProtocol, @unchecked Sendable {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "TrzszPortForwardCallback"
    )

    private weak var manager: TrzszPortForwardManager?
    private let bufferedEvents = OSAllocatedUnfairLock<[ForwardCallbackEvent]>(initialState: [])
    private let flushScheduled = OSAllocatedUnfairLock<Bool>(initialState: false)

    private nonisolated static let maxBufferedEvents = 128
    private nonisolated static let deferredFlushDelay: Duration = .milliseconds(250)

    init(manager: TrzszPortForwardManager) {
        self.manager = manager
        super.init()
    }

    private nonisolated static var shouldDeferEvents: Bool {
        if Ghostty.isInResumeQuietWindowAtomic { return true }
        return Ghostty.isAppBackgroundedAtomic
            && !BackgroundExecutionCoordinator.phase.allowsBackgroundTick
    }

    private func receive(_ event: ForwardCallbackEvent) {
        guard buffer(event) else { return }
        scheduleBufferedFlush(delay: Self.shouldDeferEvents ? Self.deferredFlushDelay : .zero)
    }

    private func buffer(_ event: ForwardCallbackEvent) -> Bool {
        bufferedEvents.withLock { events -> Bool in
            if events.count >= Self.maxBufferedEvents {
                Self.logger.warning("Dropping newest TSSH port-forward callback while foreground replay buffer is full")
                return false
            }
            events.append(event)
            return true
        }
    }

    private func scheduleBufferedFlush(delay: Duration) {
        let shouldSchedule = flushScheduled.withLock { scheduled -> Bool in
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        continueBufferedFlush(delay: delay)
    }

    private func continueBufferedFlush(delay: Duration) {
        Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            self?.flushBufferedEventsIfAllowed()
        }
    }

    @MainActor
    private func flushBufferedEventsIfAllowed() {
        if Self.shouldDeferEvents {
            continueBufferedFlush(delay: Self.deferredFlushDelay)
            return
        }

        let events = bufferedEvents.withLock { events -> [ForwardCallbackEvent] in
            let captured = events
            events.removeAll()
            return captured
        }
        flushScheduled.withLock { $0 = false }

        guard let manager else { return }
        for event in events {
            manager.handleCallbackEvent(event)
        }

        let hasMore = bufferedEvents.withLock { !$0.isEmpty }
        if hasMore {
            scheduleBufferedFlush(delay: .zero)
        }
    }

    func onForwardReady(_ id: String?, actualPort: Int) {
        guard let id else { return }
        receive(.ready(idString: id, actualPort: actualPort))
    }

    func onForwardError(_ id: String?, message: String?) {
        guard let id, let message else { return }
        receive(.error(idString: id, message: message))
    }

    func onForwardStopped(_ id: String?) {
        guard let id else { return }
        receive(.stopped(idString: id))
    }

    func onConnectionOpened(_ id: String?, connectionID: Int64) {
        guard let id else { return }
        receive(.opened(idString: id, connectionID: connectionID))
    }

    func onConnectionClosed(_ id: String?, connectionID: Int64, bytesIn: Int64, bytesOut: Int64) {
        guard let id else { return }
        receive(.closed(idString: id, connectionID: connectionID, bytesIn: bytesIn, bytesOut: bytesOut))
    }
}
