//
//  RemotePort.swift
//  rootshell
//
//  A TCP port a remote host listens on, and the parser for the one-shot
//  `ss` / `lsof` / `netstat` scan that lists them. Pure so the parser can be
//  unit tested without a connection.
//

import Foundation

/// One listening TCP port discovered on the host behind a pane.
nonisolated struct RemotePort: Hashable, Sendable, Identifiable {
    /// Where the socket listens. This decides how a tunnel must dial it.
    nonisolated enum Bind: Hashable, Sendable {
        /// The host's own loopback only: `127.0.0.1`, `127.0.0.2`, `::1`.
        case loopback(String)
        /// Every address: `*`, `0.0.0.0`, or `::`.
        case any(String)
        /// One specific, non-loopback address.
        case address(String)

        /// Which of two sockets on one port to keep: the one reachable from
        /// more places. Mirrors herdr-gpui's `Bind::reach`.
        var reach: UInt8 {
            switch self {
            case .address: return 0
            case .loopback: return 1
            case .any: return 2
            }
        }
    }

    let number: UInt16
    let bind: Bind

    var id: UInt16 { number }

    /// The host `ssh -L` should dial on the remote side. A wildcard socket
    /// accepts its own family's loopback; an IPv6 one may be v6-only, so it
    /// gets `::1`. Every other socket is dialed exactly where it listens.
    var targetHost: String {
        switch bind {
        case .any(let host):
            return host == "::" ? "::1" : "127.0.0.1"
        case .loopback(let host), .address(let host):
            return host
        }
    }

    /// `:9090`, as the status bar names it.
    var display: String { ":\(number)" }

    /// `127.0.0.1:9090` / `[::1]:9090` / `*:9090`, for a tooltip.
    var address: String {
        switch bind {
        case .any:
            return "*:\(number)"
        case .loopback(let host), .address(let host):
            return host.contains(":") ? "[\(host)]:\(number)" : "\(host):\(number)"
        }
    }
}

nonisolated struct RemotePortScanResult: Equatable, Sendable {
    var ports: [RemotePort] = []
    /// The end marker arrived. False means the transport cut the reply.
    var complete = false
    /// The host has neither `ss` nor `lsof` nor `netstat`.
    var unavailable = false
}

nonisolated enum RemotePortScanParser {
    /// A scan is cheap, but a pathological host should not stream.
    static let maxPorts = 32

    /// Parses the output of `RemotePortScanCommand`.
    ///
    /// Accepted records are `L <pid> <address>` (whitespace separated); other
    /// lines are ignored so a noisy login shell cannot fail the scan. The
    /// nonce-framed `::RSPORTS_<nonce>::` / `::END_<nonce>::` markers are
    /// handled by the caller passing the matching nonce.
    static func parse(_ output: String, nonce: String) -> RemotePortScanResult {
        let startMarker = "::RSPORTS_\(nonce)::"
        let endMarker = "::END_\(nonce)::"

        var result = RemotePortScanResult()
        var started = false
        var byPort: [UInt16: RemotePort] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == startMarker {
                started = true
                continue
            }
            if line == endMarker {
                result.complete = true
                break
            }
            guard started, !line.isEmpty else { continue }
            if line == "N" {
                result.unavailable = true
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first.map(String.init) == "L", let address = fields.last else { continue }
            guard let port = parseAddress(String(address)) else { continue }
            if let existing = byPort[port.number], existing.bind.reach >= port.bind.reach {
                continue
            }
            byPort[port.number] = port
        }

        result.ports = byPort.values
            .sorted { $0.number < $1.number }
            .prefix(maxPorts)
            .map { $0 }
        return result
    }

    /// `127.0.0.1:9090`, `[::1]:9090`, `*:9090`, `0.0.0.0:9090`.
    static func parseAddress(_ address: String) -> RemotePort? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            .rstripSpaces()
        guard !trimmed.isEmpty, let colon = trimmed.lastIndex(of: ":") else { return nil }

        var host = String(trimmed[..<colon])
        var portText = String(trimmed[trimmed.index(after: colon)...])
        // lsof may print `127.0.0.1:9090->...` for a connected socket; a
        // listening socket has no arrow, but tolerate it.
        if let arrow = portText.firstIndex(of: "-") {
            portText = String(portText[..<arrow])
        }
        guard let number = UInt16(portText), number > 0 else { return nil }

        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        // `ss` names a link-scoped interface: `fe80::1%eth0`.
        if let percent = host.firstIndex(of: "%") {
            host = String(host[..<percent])
        }
        // An IPv4-mapped address is dialed as the IPv4 address it maps.
        if host.lowercased().hasPrefix("::ffff:"), host.contains(".") {
            host = String(host.dropFirst("::ffff:".count))
        }
        guard !host.isEmpty else { return nil }

        let bind: RemotePort.Bind
        if host == "*" || host == "0.0.0.0" || host == "::" {
            bind = .any(host)
        } else if host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            bind = .loopback(host)
        } else {
            bind = .address(host)
        }
        return RemotePort(number: number, bind: bind)
    }
}

nonisolated private extension String {
    /// Trailing spaces are the only whitespace `trimmingCharacters` leaves in
    /// an address read from `ss` on some BusyBox builds.
    func rstripSpaces() -> String {
        var value = self
        while value.last == " " { value.removeLast() }
        return value
    }
}
