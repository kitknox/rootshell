//
//  MultiplexerSession.swift
//  rootshell
//
//  Unified model for terminal multiplexer sessions (tmux, zellij, herdr, zmx).
//

import Foundation

// MARK: - Multiplexer Type

enum MultiplexerType: String, Sendable, Equatable, Hashable {
    case tmux
    case zellij
    case herdr
    case zmx

    /// Whether the multiplexer, rather than its inner program, owns the screen.
    var ownsAlternateScreen: Bool {
        switch self {
        case .tmux, .zellij, .herdr: return true
        case .zmx: return false
        }
    }

    /// SF Symbol representing this multiplexer.
    ///
    var iconName: String {
        switch self {
        case .tmux: return "rectangle.split.2x1"
        case .zellij: return "rectangle.split.3x1"
        case .herdr: return "square.grid.2x2"
        case .zmx: return "rectangle"
        }
    }
}

// MARK: - Unified Session Model

struct MultiplexerSession: Identifiable, Equatable, Sendable {
    let type: MultiplexerType
    let name: String
    let isAttached: Bool
    /// Summary detail: "3w" for tmux window count, "Created 2h ago" for zellij
    let detail: String
    /// Secondary info: active command+path for tmux, nil for zellij
    let subtitle: String?
    /// Absolute working directory reported by the session.
    let workingDirectory: String?
    /// ANSI-captured terminal content for preview rendering
    var capturedContent: String?
    /// Whether this is an exited zellij session that can be resurrected
    let isExited: Bool
    /// herdr only: whether the host's herdr offers control streams. nil
    /// when unknown; false means control mode runs degraded.
    var supportsControlStream: Bool? = nil

    var id: String { "\(type.rawValue):\(name)" }
}

// MARK: - Factory: from TmuxSessionInfo

extension MultiplexerSession {
    static func from(tmux session: TmuxSessionInfo) -> MultiplexerSession {
        let detail = "\(session.windowCount)w"
        let command = session.activeCommand
        let path = session.activePath.map { shortenPath($0) }
        let subtitle = [command, path].compactMap { $0 }.joined(separator: " ")

        return MultiplexerSession(
            type: .tmux,
            name: session.name,
            isAttached: session.isAttached,
            detail: detail,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            // tmux panes are bound as a raw multiplexer, and `noteProject`
            // refuses outright inside one, so a directory here would be
            // carried and never used.
            workingDirectory: nil,
            capturedContent: session.capturedContent,
            isExited: false
        )
    }

    /// Collapses `/home/<user>` and `/Users/<user>` to `~`.
    private static func shortenPath(_ path: String) -> String {
        for root in ["/home/", "/Users/"] where path.hasPrefix(root) {
            let afterRoot = path.dropFirst(root.count)
            let username = afterRoot.prefix(while: { $0 != "/" })
            return "~" + afterRoot.dropFirst(username.count)
        }
        return path
    }
}

// MARK: - Factory: from ZellijSessionInfo

extension MultiplexerSession {
    static func from(zellij session: ZellijSessionInfo) -> MultiplexerSession {
        MultiplexerSession(
            type: .zellij,
            name: session.name,
            isAttached: session.isAttached,
            detail: session.createdAgo,
            subtitle: nil,
            workingDirectory: nil,
            capturedContent: session.capturedContent,
            isExited: session.isExited
        )
    }
}

// MARK: - Factory: from ZmxSessionInfo

extension MultiplexerSession {
    static func from(zmx session: ZmxSessionInfo) -> MultiplexerSession {
        // zmx has no windows to count; show age when nobody is attached.
        let clientCount = session.clientCount ?? 0
        let detail = clientCount > 0
            ? String(localized: "\(clientCount) clients", comment: "zmx attached client count")
            : session.createdAgo

        let subtitle = [session.labels["project"], session.cwd.map { shortenPath($0) }]
            .compactMap { $0 }
            .joined(separator: " · ")

        return MultiplexerSession(
            type: .zmx,
            name: session.name,
            isAttached: session.isAttached,
            detail: detail,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            workingDirectory: session.cwd,
            capturedContent: session.capturedContent,
            isExited: false
        )
    }
}

// MARK: - Factory: from HerdrSessionInfo

extension MultiplexerSession {
    static func from(herdr session: HerdrSessionInfo) -> MultiplexerSession {
        MultiplexerSession(
            type: .herdr,
            name: session.name,
            // herdr's session list has no attached-client notion; stopped
            // sessions surface through isExited instead.
            isAttached: false,
            detail: session.detailText,
            subtitle: session.agentSubtitle,
            // Raw-multiplexer bound like tmux; see the note there.
            workingDirectory: nil,
            capturedContent: session.capturedContent,
            isExited: !session.isRunning,
            supportsControlStream: session.supportsControlStream
        )
    }
}
