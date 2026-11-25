//
//  FileListSelection.swift
//  rootshell
//
//  Cursor and multi-selection over a list of paths, shared by keyboard,
//  pointer and touch. Tracks paths, not indexes, so it survives a refresh.
//

import Foundation

/// Byte-exact identity for a file manager row. Hashing raw UTF-8 path bytes plus
/// directory type keeps canonically equivalent Unicode spellings (e.g. NFC vs NFD
/// on S3/Ceph) and a file sharing a name with a folder independently selectable.
nonisolated struct FileEntryID: Hashable, Sendable {
    let pathBytes: [UInt8]
    let isDirectory: Bool

    init(path: String, isDirectory: Bool) {
        pathBytes = Array(path.utf8)
        self.isDirectory = isDirectory
    }

    var path: String {
        String(decoding: pathBytes, as: UTF8.self)
    }
}

nonisolated struct FileRowSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    enum ClickModifier: Sendable {
        case none
        /// ⌘-click: toggle one item.
        case toggle
        /// ⇧-click: extend from the anchor.
        case range
    }

    private(set) var selected: Set<ID> = []
    private(set) var cursor: ID?
    private var anchor: ID?

    var isEmpty: Bool { selected.isEmpty }
    var count: Int { selected.count }

    func contains(_ id: ID) -> Bool { selected.contains(id) }

    /// The selection, or the cursor item when nothing is selected.
    func effectiveIDs(in ids: [ID]) -> [ID] {
        if !selected.isEmpty { return ids.filter(selected.contains) }
        return cursor.map { [$0] } ?? []
    }

    /// Moves the cursor; with `extending`, grows or shrinks a range from the anchor.
    mutating func moveCursor(by delta: Int, in ids: [ID], extending: Bool) {
        guard !ids.isEmpty else { return }
        let current = cursor.flatMap(ids.firstIndex(of:))
        let next: Int
        if let current {
            next = min(max(current + delta, 0), ids.count - 1)
        } else {
            next = delta >= 0 ? 0 : ids.count - 1
        }
        if extending {
            if anchor == nil { anchor = cursor ?? ids[next] }
            cursor = ids[next]
            selectRange(in: ids)
        } else {
            cursor = ids[next]
            anchor = cursor
        }
    }

    mutating func setCursor(_ id: ID?) {
        cursor = id
        anchor = id
    }

    /// Space / checkmark: flips the cursor item.
    mutating func toggleCursor() {
        guard let cursor else { return }
        toggle(cursor)
    }

    mutating func toggle(_ id: ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        cursor = id
        anchor = id
    }

    mutating func click(_ id: ID, in ids: [ID], modifier: ClickModifier) {
        switch modifier {
        case .none:
            selected = [id]
            cursor = id
            anchor = id
        case .toggle:
            toggle(id)
        case .range:
            if anchor == nil { anchor = cursor ?? id }
            cursor = id
            selectRange(in: ids)
        }
    }

    mutating func selectAll(_ ids: [ID]) {
        selected = Set(ids)
    }

    mutating func clear() {
        selected = []
        anchor = cursor
    }

    /// Drops rows that no longer exist and keeps the cursor on a visible row.
    mutating func reconcile(with ids: [ID]) {
        let visible = Set(ids)
        selected.formIntersection(visible)
        if let current = cursor, !visible.contains(current) { cursor = ids.first }
        if let current = anchor, !visible.contains(current) { anchor = cursor }
    }

    private mutating func selectRange(in ids: [ID]) {
        guard let anchor, let cursor,
              let start = ids.firstIndex(of: anchor),
              let end = ids.firstIndex(of: cursor) else { return }
        selected = Set(ids[min(start, end)...max(start, end)])
    }
}

extension FileRowSelection where ID == String {
    /// The selection, or the cursor item when nothing is selected.
    func effectivePaths(in paths: [String]) -> [String] {
        effectiveIDs(in: paths)
    }
}

typealias FileListSelection = FileRowSelection<String>
