//
//  MultiplexerExposeModel.swift
//  rootshell
//
//  What the exposé shows for a raw multiplexer session (herdr, plain tmux,
//  zellij): its tabs/windows, each with the cell geometry of its panes, and
//  the latest colored frame of every pane. Multiplexer-neutral so the tray
//  and preview views never learn which one they are looking at.
//

import CryptoKit
import Foundation

/// Pane geometry in terminal cells, relative to the tab's area.
nonisolated struct MuxCellRect: Equatable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

nonisolated struct MuxPane: Equatable, Sendable {
    /// The multiplexer's own stable id (`w1:p1`, `%3`, `terminal_7`).
    let id: String
    let rect: MuxCellRect
    let isActive: Bool
    /// False for panes whose content cannot be read (zellij plugins).
    let isPreviewable: Bool
    let title: String?
}

nonisolated struct MuxTab: Equatable, Sendable {
    /// The multiplexer's own stable id (`w1:t1`, `@7`, zellij `tab_id`).
    let id: String
    /// 0-based display position.
    let index: Int
    let title: String
    let isActive: Bool
    /// Tab area in cells; pane rects live inside it.
    let cols: Int
    let rows: Int
    let panes: [MuxPane]
    /// Short trailing note for the caption (tmux flags, herdr agent status).
    let badge: String?

    /// Exposé cells are keyed by UUID; this one is stable per session + tab.
    func uuid(sessionKey: String) -> UUID {
        MuxExposeIdentity.uuid(for: "\(sessionKey)|\(id)")
    }
}

nonisolated struct MuxCursor: Equatable, Sendable {
    let x: Int
    let y: Int
    let visible: Bool
}

nonisolated struct MuxPaneFrame: Equatable, Sendable {
    /// Colored screen text, `\n` between rows.
    let ansi: String
    let cursor: MuxCursor?
    /// Changes whenever `ansi` does; equal revisions are skipped by the renderer.
    let revision: String
}

nonisolated struct MuxExposeSnapshot: Equatable, Sendable {
    let tabs: [MuxTab]
    let activeTabID: String?

    var allPanes: [MuxPane] { tabs.flatMap(\.panes) }

    func tab(withID id: String) -> MuxTab? {
        tabs.first { $0.id == id }
    }
}

/// One tick's parse: fresh topology plus whichever frames the script fetched.
nonisolated struct MuxTickResult: Sendable {
    var snapshot: MuxExposeSnapshot
    var frames: [String: MuxPaneFrame]
    /// Panes the script reported unchanged (herdr revision match).
    var unchanged: Set<String>
    /// The end marker was missing: the response was cut by the byte cap.
    var truncated: Bool
    /// Cheap per-pane "probably changed" signals (tmux activity/cursor tuple);
    /// a differing hint forces a fetch, an equal one only delays it.
    var changeHints: [String: String] = [:]
    /// Underlying terminal identity, distinct from a reusable public pane ID.
    var paneIdentities: [String: String] = [:]
}

nonisolated enum MuxExposeIdentity {
    /// Deterministic UUID (v5-shaped) from a string key.
    static func uuid(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// FNV-1a over the frame text: cheap content revision for multiplexers
    /// without a server-side counter.
    static func contentRevision(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
