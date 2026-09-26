//
//  MuxAutoStartFallback.swift
//  rootshell
//
//  Detects the missing-binary line auto-start prints before it execs $SHELL.
//

import Foundation

struct MuxAutoStartFallbackScanner: Sendable {
    private var tail = Data()
    private var fired = false

    /// Returns `tmux`, `herdr`, or `zmx` once, including when the marker is
    /// split across reads. Other output is ignored.
    mutating func consume(_ data: Data) -> String? {
        guard !fired else { return nil }
        let marker = Data(SSHConfig.muxAutoStartFallbackMarkerPrefix.utf8)
        var window = tail
        window.append(data)
        let keep = marker.count + 8
        let cap = keep + marker.count
        if window.count > cap {
            window.removeFirst(window.count - cap)
        }
        tail = window.count > keep ? Data(window.suffix(keep)) : window

        var search = window.startIndex..<window.endIndex
        while let range = window.range(of: marker, in: search) {
            let rest = window[range.upperBound...]
            guard let end = rest.firstIndex(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 }) else {
                return nil
            }
            let name = String(decoding: rest[..<end], as: UTF8.self)
            if name == "tmux" || name == "herdr" || name == "zmx" {
                fired = true
                tail.removeAll(keepingCapacity: false)
                return name
            }
            search = range.upperBound..<window.endIndex
        }
        return nil
    }
}
