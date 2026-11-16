//
//  KVMAutoWake.swift
//  rootshell
//
//  Decides when a connection without video should try to wake the computer,
//  and what it sends. Only input that cannot act on the remote system is
//  used: a small pointer move and back, then Left Control held on its own.
//  No clicks, no typing keys, no power keys, no ATX.
//

import Foundation

nonisolated enum KVMAutoWake {
    enum Verdict: Equatable {
        /// The computer is sending video; nothing to do.
        case videoPresent
        /// Too early to tell.
        case wait
        case wake
    }

    /// A pointer nudge goes out at once; these gate the key, which waits
    /// for the starting streamer to report its signal.
    static let offlineSettle: TimeInterval = 0.75
    /// With no frames and no no-signal report, how long silence counts as asleep.
    static let silentSettle: TimeInterval = 2
    /// How long to keep judging before giving up without a key press.
    static let judgeLimit: TimeInterval = 6

    /// Seconds video gets to return after each key hold. The holds stay
    /// seconds apart so they never read as a double tap.
    static let watches: [TimeInterval] = [4, 6, 8, 12]

    /// A sleeping computer's USB takes a moment to resume, and kvmd only
    /// retries the newest keyboard report: a short tap is replaced by its
    /// release before the computer is listening. A hold is still pending.
    static let keyHold: TimeInterval = 1.5
    static let nudgesPerHold = 6
    static let nudgeDistance = 4

    /// A lone modifier types nothing, and Control alone has no default
    /// action on macOS, Windows, Linux, or in firmware menus.
    static let keyCode = "ControlLeft"

    /// `framesSinceOpen` counts frames since this wake check began.
    static func verdict(
        sourceOnline: Bool?,
        framesSinceOpen: Int,
        elapsed: TimeInterval
    ) -> Verdict {
        // An awake computer's stream delivers frames at once; a device can
        // report its source online, or nothing, while the display sleeps.
        // The ATX power LED isn't consulted: it reads off with no ATX board.
        if sourceOnline != false, framesSinceOpen > 0 { return .videoPresent }
        let settle = sourceOnline == false ? offlineSettle : silentSettle
        return elapsed >= settle ? .wake : .wait
    }

    /// Two frames sent apart: a few steps away and back, so the pointer ends
    /// where it started. Without a known position an absolute pointer goes
    /// to the middle of the screen, away from edges and hot corners.
    static func pointerNudge(
        absolute: Bool,
        lastPoint: (x: Int, y: Int)?,
        frameWidth: Int,
        frameHeight: Int
    ) -> (away: Data, back: Data) {
        guard absolute else {
            let step = Int8(nudgeDistance)
            return (KVMHIDFrame.relativeMove([(step, 0)]), KVMHIDFrame.relativeMove([(-step, 0)]))
        }
        let width = max(frameWidth, nudgeDistance * 2)
        let height = max(frameHeight, 2)
        let x = min(max(lastPoint?.x ?? width / 2, 0), width - 1)
        let y = min(max(lastPoint?.y ?? height / 2, 0), height - 1)
        let awayX = x + nudgeDistance < width ? x + nudgeDistance : x - nudgeDistance
        func frame(_ x: Int) -> Data {
            KVMHIDFrame.absoluteMove(
                x: KVMHIDFrame.absoluteCoordinate(x, extent: width),
                y: KVMHIDFrame.absoluteCoordinate(y, extent: height))
        }
        return (frame(awayX), frame(x))
    }
}
